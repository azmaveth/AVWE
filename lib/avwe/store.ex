defmodule Avwe.Store do
  @moduledoc """
  A region's state on disk: an append-only log of every intent and every
  advance, and snapshots every so often.

  This is the only module that touches the disk for the simulation. The core
  (`Avwe.Region` and the systems) stays pure; `Avwe.RegionServer` calls in
  here when it accepts an intent and after each advance.

  A world is deterministic given its seed, its starting state and its input
  log (`docs/DESIGN.md`, 6.4), so the log records exactly what replay needs:
  each intent as it was accepted, with the sequence number the region gave
  it, and each advance with its step length. Events are logged too, for the
  chronicle, but replay ignores them and lets the systems emit them again.

  ## Layout

  Under `<dir>/<region_dirname>/` (`region_dirname/1` turns `{0, 0}` into
  `"0-0"`):

    * `log` - an Erlang `:disk_log` (halt log, internal format). Every record
      is `{:avwe, 2, kind}`, where the `2` is the record version and the kind
      is one of:
        * `{:submit, step, intent}` - an intent accepted while the region was
          at `step`, with the `seq` the region assigned.
        * `{:advance, entry}` - an advance; the entry has `:step`, `:time`
          and `:dt` from before the advance, the number of `:steps`, and the
          `:events` emitted.
      Version-1 records (intents inside the advance record) are rejected.
    * `snap-<step>.bin` - `:erlang.term_to_binary` of `{:avwe_snapshot, 3,
      %{region: region, definition: hash}}` for the region at `step`, with the
      step zero-padded so names sort by step. The `3` is the snapshot version:
      a file with any other tag is refused with `{:unknown_snapshot, path,
      tag}`, so a region never resumes from a snapshot that a different build
      of the code wrote. `hash` is the hash of the world definition the region
      was built from (`Avwe.Definition.hash/1`), or `nil` for a world started
      from Quire and settings; every snapshot carries it, the step-0 one
      first, so it is the header of the history that follows.

  ## Trust

  Everything here lives under the operator's `data_dir`, and the names in it
  (the world, the region, the step) come from configuration and the
  simulation; no controller supplies a path, so the file functions below
  carry `sobelow_skip` marks for directory traversal. Snapshots are decoded
  with `:erlang.binary_to_term/1`, also skipped: `:safe` would still decode
  funs, and refuses atoms that the writing build had but this one has not
  loaded yet (modules load lazily outside a release). Whoever can write a
  snapshot there can already write the log, which `:disk_log` decodes the
  same way, so the files are as trusted as the code.

  ## Durability

  Intents are journaled when they are accepted, so an intent the region
  acknowledged survives the region crashing before its next advance; that is
  what keeps "every intent ends in exactly one result percept" true across a
  restart. `:disk_log.log/2` hands the record to the log's own process, which
  keeps it in a write cache and writes the cache out after 2 s, when it
  reaches 64 KB, or when the log is synced or closed. The contract is:

    * A crash of the region process loses nothing: the log process outlives
      it, and closes (flushing) when its last owner is gone.
    * A crash of the VM loses at most the log's write cache: the records of
      the last 2 s, or the last 64 KB, whichever is less. What was written
      out is in the operating system's hands; a crash of the machine can also
      lose what it had not yet put on disk since the last sync.
    * The log is synced (fsynced) at every snapshot, *before* the snapshot is
      renamed into place, so a snapshot on disk always has the log up to its
      step behind it: a crash between the two leaves an unneeded tail of
      log, never a gap below a snapshot. The snapshot itself is written to a
      `.tmp` file, fsynced and renamed, so it is either complete or absent.

  ## Snapshots and pending intents

  A snapshot stands for the state *between* advances, so it holds no pending
  journaled intents: any still in the inbox are left out and `next_seq` is
  wound back by as many, as if they had never been submitted. Their
  `:submit` records re-submit them on replay, which gives them the same
  sequence numbers again. The intents `Avwe.Systems.Autopilot` queued during
  the last step (their refs start with `auto-`) are kept: they are derived
  state, never journaled, and the next step's replay must apply them as the
  live step did. The ref is the mark, not the intent's `controller`: what
  reaches the journal is kept out of the snapshot whoever submitted it.
  `Avwe.RegionServer` only snapshots right after an advance, when nothing
  else is pending anyway.

  ## Ownership

  The process that opens a store owns its log, and the log closes when its
  last owner exits. Several processes may open the same store (a test can
  read what a running region writes); each closes its own handle.
  """

  alias Avwe.{Event, Intent, Region, SystemTable}

  require Logger

  @version 2
  @snapshot_tag :avwe_snapshot
  @snapshot_version 3
  @log_name "log"
  @snapshot_prefix "snap-"
  @snapshot_suffix ".bin"
  @snapshot_digits 10
  @default_keep 5

  @enforce_keys [:dir, :region_id, :path, :log]
  defstruct [:dir, :region_id, :path, :log]

  @type t :: %__MODULE__{
          dir: Path.t(),
          region_id: term(),
          path: Path.t(),
          log: term()
        }

  @type advance :: %{
          step: non_neg_integer(),
          time: Avwe.Calendar.time(),
          dt: pos_integer(),
          steps: non_neg_integer(),
          events: [Event.t()]
        }

  @type record ::
          {:avwe, 2, {:submit, non_neg_integer(), Intent.t()}}
          | {:avwe, 2, {:advance, advance()}}

  # Opening and closing

  @doc "The tag and version of the snapshots this build writes and reads."
  @spec snapshot_tag() :: {atom(), pos_integer()}
  def snapshot_tag, do: {@snapshot_tag, @snapshot_version}

  @doc "The folder name of a region's state under the store's dir."
  @spec region_dirname(term()) :: String.t()
  def region_dirname(id) when is_tuple(id), do: id |> Tuple.to_list() |> Enum.join("-")
  def region_dirname(id), do: to_string(id)

  @doc """
  Opens the store for one region under `dir`, creating its folder and log if
  they don't exist. The calling process owns the log until it closes the
  store or exits.

  Only the region that writes the store should open it with `owner: true`:
  that removes any snapshot left half-written by a crash. A reader must not,
  because the `.tmp` it finds may be a snapshot the running region is in the
  middle of writing.
  """
  @spec open(Path.t(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(dir, region_id, opts \\ []) do
    dir = Path.expand(dir)
    path = Path.join(dir, region_dirname(region_id))

    with :ok <- mkdir(path),
         :ok <- if(opts[:owner], do: remove_partial_snapshots(path), else: :ok),
         {:ok, log} <- open_log({:avwe_store, dir, region_id}, Path.join(path, @log_name)) do
      {:ok, %__MODULE__{dir: dir, region_id: region_id, path: path, log: log}}
    end
  end

  @doc "True when the log has no records at all. Reads one chunk, never the whole log."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{log: log}), do: :disk_log.chunk(log, :start) == :eof

  @doc "Closes the calling process's handle on the store's log."
  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{log: log}), do: :disk_log.close(log)

  # sobelow_skip ["Traversal.FileModule"]
  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, path, reason}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_partial_snapshots(path) do
    path
    |> Path.join(@snapshot_prefix <> "*" <> @snapshot_suffix <> ".tmp")
    |> Path.wildcard()
    |> Enum.each(fn tmp ->
      Logger.warning("Removing half-written snapshot #{tmp}")
      File.rm(tmp)
    end)
  end

  defp open_log(name, file) do
    opts = [name: name, file: to_charlist(file), type: :halt, format: :internal]

    case :disk_log.open(opts) do
      {:ok, log} ->
        {:ok, log}

      {:repaired, log, {:recovered, good}, {:badbytes, bad}} ->
        Logger.warning("Repaired #{file}: kept #{good} records, dropped #{bad} bytes")
        {:ok, log}

      {:error, reason} ->
        {:error, {:open_log, file, reason}}
    end
  end

  # The log

  @doc """
  The record of accepting `intent` while the region was at `step`. The intent
  must carry the `seq` the region assigned it.
  """
  @spec submit_record(non_neg_integer(), Intent.t()) :: record()
  def submit_record(step, %Intent{} = intent) when is_integer(step) do
    {:avwe, @version, {:submit, step, intent}}
  end

  @doc """
  The record of advancing `before` by `steps` of `dt` seconds each, which
  emitted `events`.
  """
  @spec advance_record(Region.t(), non_neg_integer(), pos_integer(), [Event.t()]) :: record()
  def advance_record(%Region{} = before, steps, dt, events) when is_integer(dt) do
    {:avwe, @version,
     {:advance, %{step: before.step, time: before.time, dt: dt, steps: steps, events: events}}}
  end

  @doc "Appends one record to the log."
  @spec append(t(), record()) :: :ok | {:error, term()}
  def append(%__MODULE__{log: log}, {:avwe, @version, {:submit, _step, %Intent{}}} = record) do
    :disk_log.log(log, record)
  end

  def append(%__MODULE__{log: log}, {:avwe, @version, {:advance, %{} = _entry}} = record) do
    :disk_log.log(log, record)
  end

  @doc """
  Every record in the log, oldest first. This reads the whole log into
  memory; it is for tests and tools. A region resuming uses
  `records_after/2`.
  """
  @spec records(t()) :: {:ok, [record()]} | {:error, term()}
  def records(%__MODULE__{} = store), do: read_log(store, fn _record -> true end)

  @doc """
  The records from `step` on: what replaying a snapshot taken at `step` needs.
  Records of an unknown shape are kept, so replay can reject them.

  The log is read one `:disk_log` chunk (64 KB) at a time and the records
  below `step` are dropped as each chunk is read, so what this holds at once
  is the tail plus one chunk, however long the history before the snapshot
  has grown. A world's log is never truncated, so this is what keeps a
  restart's memory from growing with the world's age.
  """
  @spec records_after(t(), non_neg_integer()) :: {:ok, [record()]} | {:error, term()}
  def records_after(%__MODULE__{} = store, step) do
    read_log(store, fn record -> (record_step(record) || step) >= step end)
  end

  defp record_step({:avwe, @version, {:submit, step, _intent}}), do: step
  defp record_step({:avwe, @version, {:advance, %{step: step}}}), do: step
  defp record_step(_record), do: nil

  # Reads the log chunk by chunk, keeping only the records `keep?` accepts.
  # A chunk's terms are kept or dropped before the next chunk is asked for,
  # so a rejected head is never in memory as a whole.
  defp read_log(%__MODULE__{log: log}, keep?), do: read_chunks(log, :start, keep?, [])

  defp read_chunks(log, continuation, keep?, acc) do
    case :disk_log.chunk(log, continuation) do
      :eof -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, {:read_log, log, reason}}
      {next, terms} -> read_chunks(log, next, keep?, keep(terms, keep?, acc))
      {next, terms, _badbytes} -> read_chunks(log, next, keep?, keep(terms, keep?, acc))
    end
  end

  defp keep(terms, keep?, acc) do
    Enum.reduce(terms, acc, fn term, acc -> if keep?.(term), do: [term | acc], else: acc end)
  end

  # Snapshots

  @doc """
  Syncs the log, writes the region as the snapshot for its step, then prunes
  old snapshots. Option `:keep` (default #{@default_keep}) is how many of the
  newest snapshots to keep besides the first one, which is always kept so
  the whole history can be replayed; `:infinity` keeps them all. Option
  `:definition` is the hash of the world definition the region comes from
  (default `nil`: none).

  The log is synced first, on purpose: a snapshot that is on disk before the
  log behind it would, after a crash between the two, leave a gap below the
  snapshot that `rebuild_from_start/1` could never close. A log that reaches
  further than the newest snapshot is only a longer replay.
  """
  @spec snapshot(t(), Region.t(), keyword()) :: :ok | {:error, term()}
  def snapshot(%__MODULE__{} = store, %Region{} = region, opts \\ []) do
    keep = Keyword.get(opts, :keep, @default_keep)
    path = snapshot_path(store, region.step)
    payload = %{region: unsubmit_pending(region), definition: Keyword.get(opts, :definition)}
    binary = :erlang.term_to_binary({@snapshot_tag, @snapshot_version, payload})

    with :ok <- :disk_log.sync(store.log),
         :ok <- write_atomically(path, binary) do
      prune(store, keep)
    end
  end

  @doc "The steps that have a snapshot, oldest first."
  @spec snapshots(t()) :: [non_neg_integer()]
  def snapshots(%__MODULE__{path: path}) do
    case File.ls(path) do
      {:ok, names} -> names |> Enum.flat_map(&snapshot_step/1) |> Enum.sort()
      {:error, _reason} -> []
    end
  end

  @doc "The newest snapshot, or `:none`."
  @spec latest_snapshot(t()) :: {:ok, Region.t()} | :none | {:error, term()}
  def latest_snapshot(%__MODULE__{} = store) do
    case snapshots(store) do
      [] -> :none
      steps -> store |> read_snapshot(List.last(steps)) |> without_definition()
    end
  end

  @doc "The oldest snapshot (the step-0 one, unless it was removed), or `:none`."
  @spec first_snapshot(t()) :: {:ok, Region.t()} | :none | {:error, term()}
  def first_snapshot(%__MODULE__{} = store),
    do: store |> oldest_snapshot() |> without_definition()

  defp oldest_snapshot(store) do
    case snapshots(store) do
      [] -> :none
      [first | _rest] -> read_snapshot(store, first)
    end
  end

  defp without_definition({:ok, region, _definition}), do: {:ok, region}
  defp without_definition(other), do: other

  # The newest snapshot that decodes, skipping (and naming) any that don't.
  defp newest_readable_snapshot(store) do
    store |> snapshots() |> Enum.reverse() |> newest_readable_snapshot(store, :none)
  end

  defp newest_readable_snapshot([], _store, last_error), do: last_error

  defp newest_readable_snapshot([step | older], store, _last_error) do
    case read_snapshot(store, step) do
      {:ok, _region, _definition} = snapshot ->
        snapshot

      {:error, reason} = error ->
        Logger.warning("Skipping snapshot #{snapshot_path(store, step)}: #{inspect(reason)}")
        newest_readable_snapshot(older, store, error)
    end
  end

  # Autopilot's intents stay: they are derived state, queued by a system
  # during the step and never journaled, so a snapshot that dropped them
  # would lose a decision on replay. They were queued during the advance,
  # before any journaled intent that is still pending, so the pending
  # journaled ones hold the highest seqs and winding back by their count
  # leaves autopilot's seqs as they were. Autopilot's refs are its mark
  # (`Avwe.Session` refuses them to controllers).
  defp unsubmit_pending(%Region{inbox: inbox, next_seq: next_seq} = region) do
    kept = Enum.filter(inbox, &derived?/1)
    %{region | inbox: kept, outbox: [], next_seq: next_seq - (length(inbox) - length(kept))}
  end

  defp derived?(%{ref: ref}), do: String.starts_with?(ref, "auto-")

  # Written to a .tmp file, fsynced, then renamed into place, so the snapshot
  # is either whole or not there at all.
  defp write_atomically(path, binary) do
    tmp = path <> ".tmp"

    with :ok <- write_synced(tmp, binary),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> {:error, {:write_snapshot, path, reason}}
    end
  end

  defp write_synced(path, binary) do
    with {:ok, fd} <- :file.open(path, [:write, :binary, :raw]) do
      result =
        with :ok <- :file.write(fd, binary) do
          :file.sync(fd)
        end

      :file.close(fd)
      result
    end
  end

  defp prune(_store, :infinity), do: :ok

  defp prune(store, keep) when is_integer(keep) and keep >= 0 do
    case snapshots(store) do
      [] ->
        :ok

      [_first | rest] ->
        rest |> Enum.reverse() |> Enum.drop(keep) |> Enum.each(&remove(store, &1))
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove(store, step), do: File.rm(snapshot_path(store, step))

  # sobelow_skip ["Traversal.FileModule"]
  defp read_snapshot(store, step) do
    path = snapshot_path(store, step)

    case File.read(path) do
      {:ok, binary} -> decode_snapshot(binary, path)
      {:error, reason} -> {:error, {:read_snapshot, path, reason}}
    end
  end

  # A file that doesn't decode at all is corrupt. One that decodes but isn't
  # `{:avwe_snapshot, 3, %{region: region, definition: hash}}` was written by
  # other code: an earlier or later version of this one, or the untagged
  # format from before the tag. The tag names which, so the error can say
  # what the file is.
  # sobelow_skip ["Misc.BinToTerm"]
  defp decode_snapshot(binary, path) do
    case :erlang.binary_to_term(binary) do
      {@snapshot_tag, @snapshot_version, %{region: %Region{} = region} = payload} ->
        {:ok, region, Map.get(payload, :definition)}

      {@snapshot_tag, @snapshot_version, _not_a_region} ->
        {:error, {:corrupt_snapshot, path}}

      other ->
        {:error, {:unknown_snapshot, path, snapshot_tag(other)}}
    end
  rescue
    ArgumentError -> {:error, {:corrupt_snapshot, path}}
  end

  defp snapshot_tag({tag, version, _payload}) when is_atom(tag), do: {tag, version}
  defp snapshot_tag(_other), do: :untagged

  defp snapshot_path(%__MODULE__{path: path}, step) do
    padded = step |> Integer.to_string() |> String.pad_leading(@snapshot_digits, "0")
    Path.join(path, @snapshot_prefix <> padded <> @snapshot_suffix)
  end

  defp snapshot_step(@snapshot_prefix <> rest) do
    case Integer.parse(rest) do
      {step, @snapshot_suffix} -> [step]
      _other -> []
    end
  end

  defp snapshot_step(_name), do: []

  # Rebuilding

  @doc """
  The region as it was after the last logged record: the newest snapshot
  with every later record replayed onto it. A snapshot that doesn't decode,
  or carries another version's tag, is skipped for the next older one (with
  a warning), since the log reaches back to the first; it is an error only
  if none can be read. `:none` if nothing was saved.
  """
  @spec rebuild(t()) :: {:ok, Region.t()} | :none | {:error, term()}
  def rebuild(%__MODULE__{} = store),
    do: store |> rebuild_with_definition() |> without_definition()

  @doc """
  `rebuild/1`, and the hash of the world definition the snapshot it started
  from was written under (`nil` for a world with none).
  """
  @spec rebuild_with_definition(t()) ::
          {:ok, Region.t(), String.t() | nil} | :none | {:error, term()}
  def rebuild_with_definition(%__MODULE__{} = store),
    do: replay_from(store, newest_readable_snapshot(store))

  @doc """
  The same state as `rebuild/1`, but reached from the first snapshot through
  the whole log. That the two agree is the determinism check.
  """
  @spec rebuild_from_start(t()) :: {:ok, Region.t()} | :none | {:error, term()}
  def rebuild_from_start(%__MODULE__{} = store),
    do: store |> oldest_snapshot() |> then(&replay_from(store, &1)) |> without_definition()

  defp replay_from(store, {:ok, %Region{} = region, definition}) do
    with :ok <- known_systems(region),
         {:ok, records} <- records_after(store, region.step),
         {:ok, rebuilt} <- replay_all(region, records),
         do: {:ok, rebuilt, definition}
  end

  defp replay_from(_store, other), do: other

  # A snapshot lists its systems by id; replaying it needs a module for each.
  defp known_systems(%Region{systems: systems}) do
    case systems |> Enum.map(&elem(&1, 0)) |> SystemTable.missing() do
      [] -> :ok
      ids -> {:error, {:unknown_systems, ids}}
    end
  end

  defp replay_all(region, records) do
    Enum.reduce_while(records, {:ok, region}, fn record, {:ok, acc} ->
      case replay(acc, record) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  # Re-submitting an intent at the step it was accepted gives it the same seq
  # it had live, and so the same order of application. The log carries the
  # live seq, so a mismatch means the order or `next_seq` has drifted.
  defp replay(%Region{step: step} = region, {:avwe, @version, {:submit, step, intent}}) do
    resubmit(region, intent)
  end

  defp replay(%Region{step: step} = region, {:avwe, @version, {:advance, %{step: step} = entry}}) do
    {_events, region} =
      region |> Region.advance(entry.steps, dt: entry.dt) |> Region.drain_events()

    {:ok, region}
  end

  defp replay(%Region{step: step}, {:avwe, @version, {:submit, other, _intent}}) do
    {:error, {:log_gap, step, other}}
  end

  defp replay(%Region{step: step}, {:avwe, @version, {:advance, %{step: other}}}) do
    {:error, {:log_gap, step, other}}
  end

  defp replay(_region, record), do: {:error, {:unknown_record, record}}

  defp resubmit(%Region{next_seq: seq} = region, %Intent{seq: seq} = intent) do
    {:ok, Region.submit(region, intent)}
  end

  defp resubmit(%Region{next_seq: seq, step: step}, %Intent{} = intent) do
    {:error, {:seq_mismatch, step, intent.seq, seq}}
  end
end
