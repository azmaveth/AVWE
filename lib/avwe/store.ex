defmodule Avwe.Store do
  @moduledoc """
  A region's state on disk: an append-only log of every advance, and
  snapshots every so often.

  This is the only module that touches the disk for the simulation. The core
  (`Avwe.Region` and the systems) stays pure; `Avwe.RegionServer` calls in
  here after each advance.

  A world is deterministic given its seed, its starting state and its input
  log (`docs/DESIGN.md`, 6.4), so the log records exactly what replay needs:
  for each advance, the intents that were applied, in the order they were
  submitted, and the step length. Events are logged too, for the chronicle,
  but replay ignores them and lets the systems emit them again.

  ## Layout

  Under `<dir>/<region_dirname>/` (`region_dirname/1` turns `{0, 0}` into
  `"0-0"`):

    * `log` - an Erlang `:disk_log` (halt log, internal format). One record
      per advance: `{:avwe, 1, entry}`, where the `1` is the record version
      and the entry has `:step`, `:time` and `:dt` from before the advance,
      the number of `:steps`, the `:intents` applied and the `:events`
      emitted.
    * `snap-<step>.bin` - `:erlang.term_to_binary` of the region at `step`,
      with the step zero-padded so names sort by step.

  ## Snapshots and pending intents

  A snapshot stands for the state *between* advances, so it holds no pending
  intents: any still in the inbox are left out and `next_seq` is wound back
  by as many, as if they had never been submitted. The record of the advance
  that applies them re-submits them on replay, which gives them the same
  sequence numbers again. `Avwe.RegionServer` only snapshots right after an
  advance, when the inbox is empty anyway.

  ## Ownership

  The process that opens a store owns its log, and the log closes when its
  last owner exits. Several processes may open the same store (a test can
  read what a running region writes); each closes its own handle.
  """

  alias Avwe.{Event, Intent, Region}

  require Logger

  @version 1
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

  @type entry :: %{
          step: non_neg_integer(),
          time: Avwe.Calendar.time(),
          dt: pos_integer(),
          steps: non_neg_integer(),
          intents: [Intent.t()],
          events: [Event.t()]
        }

  @type record :: {:avwe, 1, entry()}

  # Opening and closing

  @doc "The folder name of a region's state under the store's dir."
  @spec region_dirname(term()) :: String.t()
  def region_dirname(id) when is_tuple(id), do: id |> Tuple.to_list() |> Enum.join("-")
  def region_dirname(id), do: to_string(id)

  @doc """
  Opens the store for one region under `dir`, creating its folder and log if
  they don't exist. The calling process owns the log until it closes the
  store or exits.
  """
  @spec open(Path.t(), term()) :: {:ok, t()} | {:error, term()}
  def open(dir, region_id) do
    dir = Path.expand(dir)
    path = Path.join(dir, region_dirname(region_id))

    with :ok <- mkdir(path),
         {:ok, log} <- open_log({:avwe_store, dir, region_id}, Path.join(path, @log_name)) do
      {:ok, %__MODULE__{dir: dir, region_id: region_id, path: path, log: log}}
    end
  end

  @doc "Closes the calling process's handle on the store's log."
  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{log: log}), do: :disk_log.close(log)

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, path, reason}}
    end
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
  The record of advancing `before` by `steps`, which emitted `events`. The
  intents are the ones pending in `before`, in submission order.
  """
  @spec record(Region.t(), non_neg_integer(), [Event.t()]) :: record()
  def record(%Region{} = before, steps, events) do
    {:avwe, @version,
     %{
       step: before.step,
       time: before.time,
       dt: before.dt,
       steps: steps,
       intents: Region.pending(before),
       events: events
     }}
  end

  @doc "Appends one record to the log."
  @spec append(t(), record()) :: :ok | {:error, term()}
  def append(%__MODULE__{log: log}, {:avwe, @version, %{} = _entry} = record) do
    :disk_log.log(log, record)
  end

  @doc "Every record in the log, oldest first."
  @spec records(t()) :: [record()]
  def records(%__MODULE__{log: log}), do: read_chunks(log, :start, [])

  @doc """
  The records of the advances made from `step` on: what replaying a snapshot
  taken at `step` needs.
  """
  @spec records_after(t(), non_neg_integer()) :: [record()]
  def records_after(%__MODULE__{} = store, step) do
    store |> records() |> Enum.filter(fn {:avwe, _version, entry} -> entry.step >= step end)
  end

  defp read_chunks(log, continuation, acc) do
    case :disk_log.chunk(log, continuation) do
      :eof -> Enum.reverse(acc)
      {:error, reason} -> raise "can't read #{inspect(log)}: #{inspect(reason)}"
      {next, terms} -> read_chunks(log, next, Enum.reverse(terms, acc))
      {next, terms, _badbytes} -> read_chunks(log, next, Enum.reverse(terms, acc))
    end
  end

  # Snapshots

  @doc """
  Writes the region as the snapshot for its step and syncs the log, then
  prunes old snapshots. Option `:keep` (default #{@default_keep}) is how many
  of the newest snapshots to keep besides the first one, which is always
  kept so the whole history can be replayed; `:infinity` keeps them all.
  """
  @spec snapshot(t(), Region.t(), keyword()) :: :ok | {:error, term()}
  def snapshot(%__MODULE__{} = store, %Region{} = region, opts \\ []) do
    keep = Keyword.get(opts, :keep, @default_keep)
    path = snapshot_path(store, region.step)
    binary = :erlang.term_to_binary(unsubmit_pending(region))

    with :ok <- write_atomically(path, binary),
         :ok <- :disk_log.sync(store.log) do
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
      steps -> read_snapshot(store, List.last(steps))
    end
  end

  @doc "The oldest snapshot (the step-0 one, unless it was removed), or `:none`."
  @spec first_snapshot(t()) :: {:ok, Region.t()} | :none | {:error, term()}
  def first_snapshot(%__MODULE__{} = store) do
    case snapshots(store) do
      [] -> :none
      [first | _rest] -> read_snapshot(store, first)
    end
  end

  defp unsubmit_pending(%Region{inbox: inbox, next_seq: next_seq} = region) do
    %{region | inbox: [], outbox: [], next_seq: next_seq - length(inbox)}
  end

  defp write_atomically(path, binary) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, binary),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> {:error, {:write_snapshot, path, reason}}
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

  defp remove(store, step), do: File.rm(snapshot_path(store, step))

  defp read_snapshot(store, step) do
    path = snapshot_path(store, step)

    case File.read(path) do
      {:ok, binary} -> decode_snapshot(binary, path)
      {:error, reason} -> {:error, {:read_snapshot, path, reason}}
    end
  end

  defp decode_snapshot(binary, path) do
    case :erlang.binary_to_term(binary) do
      %Region{} = region -> {:ok, region}
      _other -> {:error, {:corrupt_snapshot, path}}
    end
  rescue
    ArgumentError -> {:error, {:corrupt_snapshot, path}}
  end

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
  The region as it was after the last logged advance: the newest snapshot
  with every later record replayed onto it. `:none` if nothing was saved.
  """
  @spec rebuild(t()) :: {:ok, Region.t()} | :none | {:error, term()}
  def rebuild(%__MODULE__{} = store), do: replay_from(store, latest_snapshot(store))

  @doc """
  The same state as `rebuild/1`, but reached from the first snapshot through
  the whole log. That the two agree is the determinism check.
  """
  @spec rebuild_from_start(t()) :: {:ok, Region.t()} | :none | {:error, term()}
  def rebuild_from_start(%__MODULE__{} = store), do: replay_from(store, first_snapshot(store))

  defp replay_from(store, {:ok, %Region{} = region}) do
    store
    |> records_after(region.step)
    |> Enum.reduce_while({:ok, region}, fn record, {:ok, acc} ->
      case replay(acc, record) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp replay_from(_store, other), do: other

  # Re-submitting the intents in submission order gives them the same seqs
  # they had live, and so the same order of application. The log carries the
  # live seqs, so a mismatch means the order or `next_seq` has drifted.
  defp replay(%Region{step: step} = region, {:avwe, @version, %{step: step} = entry}) do
    with {:ok, region} <- resubmit(region, entry.intents) do
      {_events, region} =
        region |> Region.advance(entry.steps, dt: entry.dt) |> Region.drain_events()

      {:ok, region}
    end
  end

  defp replay(%Region{step: step}, {:avwe, @version, %{step: other}}) do
    {:error, {:log_gap, step, other}}
  end

  defp replay(_region, record), do: {:error, {:unknown_record, record}}

  defp resubmit(region, []), do: {:ok, region}

  defp resubmit(%Region{next_seq: seq} = region, [%Intent{seq: seq} = intent | rest]) do
    resubmit(Region.submit(region, intent), rest)
  end

  defp resubmit(%Region{next_seq: seq, step: step}, [%Intent{} = intent | _rest]) do
    {:error, {:seq_mismatch, step, intent.seq, seq}}
  end
end
