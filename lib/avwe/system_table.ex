defmodule Avwe.SystemTable do
  @moduledoc """
  Which module runs a system, by the system's id.

  A region lists its systems by id (`Avwe.Region`), and `state_hash/1` and
  every snapshot see only the ids, so moving or renaming the module that
  implements a system breaks no saved world: the id stays and the table says
  which module it is now. A system names its id itself (`c:Avwe.System.system_id/0`,
  `"earthlike.heat/step"`: its rule, a slash, its name); a module that does not
  has the id `"module:" <> inspect(module)`, which is for tests and for
  systems made on the spot, and which a rename does change.

  The table is filled when a region is built (`Avwe.Region.new/1` registers
  the modules it is given) and when rules are loaded (`Avwe.Ruleset`). It is
  read for every system in every step, so it lives in `:persistent_term`, and
  it is written rarely and only to say what a module already declares: an id
  belongs to one module, and a second module that declares it is refused.
  `put/2` is the one way to point an id at another module, for the day a
  system moves.
  """

  @type id :: String.t()

  @doc "The id of a system module: the one it declares, or one made from its name."
  @spec id(module()) :: id()
  def id(module) when is_atom(module) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :system_id, 0),
      do: module.system_id(),
      else: "module:" <> inspect(module)
  end

  @doc """
  Registers a system module under its id and returns the id. Raises when
  another module already runs that id.
  """
  @spec register(module()) :: id()
  def register(module) when is_atom(module) do
    id = id(module)

    case fetch(id) do
      {:ok, ^module} ->
        id

      {:ok, other} ->
        raise ArgumentError,
              "the system id #{inspect(id)} belongs to #{inspect(other)}, " <>
                "and #{inspect(module)} declares it too"

      :error ->
        put(id, module)
        id
    end
  end

  @doc "Says that `module` runs the system `id` from now on."
  @spec put(id(), module()) :: :ok
  def put(id, module) when is_binary(id) and is_atom(module) do
    :persistent_term.put({__MODULE__, id}, module)
  end

  @doc """
  The module that runs the system `id`. An id the table has not been told of
  is looked for among the systems of the rules the packages ship
  (`Avwe.Ruleset.register_known/0`, which the application also does when it
  starts), once, before it is said to be unknown.
  """
  @spec fetch(id()) :: {:ok, module()} | :error
  def fetch(id) when is_binary(id) do
    with :error <- lookup(id) do
      :ok = Avwe.Ruleset.register_known()
      lookup(id)
    end
  end

  defp lookup(id) do
    case :persistent_term.get({__MODULE__, id}, nil) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  @doc "The module that runs the system `id`; raises when no rule has declared it."
  @spec fetch!(id()) :: module()
  def fetch!(id) do
    case fetch(id) do
      {:ok, module} -> module
      :error -> raise ArgumentError, unknown(id)
    end
  end

  @doc "The ids among `ids` that no module runs, in the order given."
  @spec missing([id()]) :: [id()]
  def missing(ids), do: Enum.reject(ids, &match?({:ok, _module}, fetch(&1)))

  @doc "What to say of a system id that nothing runs."
  @spec unknown(id()) :: String.t()
  def unknown(id) do
    "no rule declares the system #{inspect(id)}; a world that was saved with it can only " <>
      "be resumed by a build that has it"
  end
end
