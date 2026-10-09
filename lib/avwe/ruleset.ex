defmodule Avwe.Ruleset do
  @moduledoc """
  The rules a world runs, and the check that they make a world.

  A ruleset is a list of rules (`Avwe.Rule`), named in a world's definition by
  a preset (`"earthlike"`), rules added to it and rules left out, or by an
  explicit list; `sim` always runs. `resolve/1` turns that into rule modules,
  and `plan/2` checks them and says in what order their systems run:

    * **ownership**: no state key is owned by two rules;
    * **needs**: every capability a rule requires is provided by a rule in the
      set (one it only uses may be missing);
    * **conflicts**: no rule runs beside one it conflicts with;
    * **names**: a rule is listed once, and a system module declares the id
      its rule gives it;
    * **order**: the constraints (`runs_after`, `runs_before`, and the order
      of a rule's own systems) can all be met, and what they leave open is
      sorted by id, so the same ruleset always runs in the same order.

  Everything wrong is reported at once, each problem in plain words (`"station.scrubbers
  needs :power, which no rule in this ruleset provides (station.grid does)"`).
  Pure but for reading `config :avwe, :rule_packages`.
  """

  alias Avwe.{Rule, SystemTable}

  @engine "sim"
  @constraints [:runs_after, :runs_before]

  @typedoc "A world's `ruleset` section: a preset and changes to it, or an explicit list."
  @type spec :: nil | %{optional(atom()) => term()}

  @type plan :: %{
          rules: [map()],
          systems: [%{id: String.t(), module: module(), options: keyword()}],
          providers: %{atom() => [String.t()]},
          owners: %{Rule.key() => String.t()}
        }

  # The packages and what they ship

  @doc "The rule packages, from `config :avwe, :rule_packages`."
  @spec packages() :: [module()]
  def packages, do: Application.get_env(:avwe, :rule_packages, [])

  @doc "Every rule the packages ship, and the kernel's own `sim`, by id."
  @spec known() :: %{String.t() => module()}
  def known do
    for module <- [Avwe.Rules.Sim | Enum.flat_map(packages(), & &1.rules())],
        into: %{},
        do: {module.id(), module}
  end

  @doc "The presets the packages name."
  @spec presets() :: %{String.t() => [String.t()]}
  def presets do
    Enum.reduce(packages(), %{}, fn package, acc -> Map.merge(acc, package.presets()) end)
  end

  @doc """
  The ruleset a definition without a `ruleset` section runs: the preset named
  in `config :avwe, :default_preset`, or `sim` alone.
  """
  @spec default() :: %{optional(atom()) => term()}
  def default do
    case Application.get_env(:avwe, :default_preset) do
      nil -> %{rules: []}
      name -> %{preset: name}
    end
  end

  # Resolving what a definition says

  @doc """
  The rule modules a `ruleset` section names, sorted by id, with `sim` among
  them. `nil` is the default ruleset (`default/0`). The section is `%{preset: name, with: ids,
  without: ids}` (`with` and `without` optional) or `%{rules: ids}`.
  """
  @spec resolve(spec()) :: {:ok, [module()]} | {:error, [String.t()]}
  def resolve(spec) do
    known = known()

    with {:ok, ids} <- ids(Map.new(spec || default())),
         ids = Enum.uniq([@engine | ids]),
         [] <- unknown(ids, known) do
      {:ok, ids |> Enum.sort() |> Enum.map(&Map.fetch!(known, &1))}
    else
      problems when is_list(problems) -> {:error, problems}
      {:error, problems} -> {:error, problems}
    end
  end

  defp ids(%{rules: rules}) when is_list(rules), do: {:ok, rules}

  defp ids(%{preset: name} = spec) do
    case Map.fetch(presets(), name) do
      {:ok, ids} ->
        without = Map.get(spec, :without, [])
        {:ok, (ids ++ Map.get(spec, :with, [])) -- without}

      :error ->
        {:error, ["no ruleset preset is named #{inspect(name)} (#{list(Map.keys(presets()))})"]}
    end
  end

  defp ids(_other),
    do: {:error, ["a ruleset is a preset (with rules added and left out) or a list of rules"]}

  defp unknown(ids, known) do
    for id <- ids, not is_map_key(known, id) do
      "no rule has the id #{inspect(id)} (#{list(Map.keys(known))})"
    end
  end

  # The check

  @doc """
  Checks `modules` as a ruleset and plans it: the rules with their manifests
  and the systems in the order they run, each as `%{id, module, options}`, or
  every problem found. Option `:known` is the rules to look in when saying
  what could have been provided (default: every rule the packages ship).
  """
  @spec plan([module() | map()], keyword()) :: {:ok, plan()} | {:error, [String.t()]}
  def plan(rules, opts \\ []) when is_list(rules) do
    known = Keyword.get_lazy(opts, :known, fn -> known() |> Map.values() |> manifests() end)
    rules = manifests(rules)
    {order, order_problems} = order(rules, known)

    problems =
      Enum.uniq(
        duplicates(rules) ++
          conflicts(rules) ++
          ownership(rules) ++
          needs(rules, known) ++
          system_ids(rules) ++
          order_problems
      )

    if problems == [] do
      {:ok,
       %{
         rules: rules,
         systems: order,
         providers: providers(rules),
         owners: owners(rules)
       }}
    else
      {:error, Enum.sort(problems)}
    end
  end

  @doc "`resolve/1` and `plan/2` in one: the plan for what a definition's `ruleset` section says."
  @spec plan_for(spec()) :: {:ok, plan()} | {:error, [String.t()]}
  def plan_for(spec) do
    with {:ok, modules} <- resolve(spec), do: plan(modules)
  end

  @doc "The systems of a plan as a region keeps them: `{id, options}`, in order."
  @spec systems(plan()) :: [{String.t(), keyword()}]
  def systems(%{systems: systems}), do: Enum.map(systems, &{&1.id, &1.options})

  @doc """
  Makes the modules of a plan known to `Avwe.SystemTable`, so that a region
  can run them by id. Idempotent.
  """
  @spec register(plan()) :: :ok
  def register(%{systems: systems}) do
    Enum.each(systems, &SystemTable.put(&1.id, &1.module))
  end

  @doc """
  Makes every system of every rule the packages ship known to
  `Avwe.SystemTable`, so that a saved world can be replayed whatever ruleset it
  is now started under. The application does it when it starts.
  """
  @spec register_known() :: :ok
  def register_known do
    for module <- Map.values(known()),
        system <- Rule.manifest(module).systems,
        do: SystemTable.put(system.id, system.module)

    :ok
  end

  # Rules are given as modules, or as manifests (`Avwe.Rule.manifest/1`) that a
  # tool has changed.
  defp manifests(rules), do: Enum.map(rules, &manifest/1)
  defp manifest(%{id: _id} = manifest), do: manifest
  defp manifest(module), do: Rule.manifest(module)

  # Names

  defp duplicates(rules) do
    for {id, [_first, _second | _rest]} <- Enum.group_by(rules, & &1.id) do
      "the rule #{id} is listed twice"
    end
  end

  defp system_ids(rules) do
    for rule <- rules, system <- rule.systems, SystemTable.id(system.module) != system.id do
      "#{rule.id} lists its system #{system.name} as #{inspect(system.module)}, " <>
        "whose id is #{SystemTable.id(system.module)} and not #{system.id}"
    end
  end

  # Conflicts

  defp conflicts(rules) do
    listed = MapSet.new(rules, & &1.id)

    for rule <- rules, other <- rule.conflicts, other in listed do
      [first, second] = Enum.sort([rule.id, other])
      "#{first} cannot run beside #{second}"
    end
  end

  # Ownership

  defp owners(rules) do
    for rule <- rules, key <- rule.owns, into: %{}, do: {key, rule.id}
  end

  defp ownership(rules) do
    claims = for rule <- rules, key <- rule.owns, do: {key, rule.id}

    for {key, owners} <- Enum.group_by(claims, &elem(&1, 0), &elem(&1, 1)),
        [_first, _second | _rest] = owners <- [Enum.sort(Enum.uniq(owners))] do
      "#{describe(key)} is owned by both #{Enum.join(owners, " and ")}; a rule that wants to " <>
        "affect another's state feeds it through entities of its own or through events"
    end
  end

  defp describe({:component, name}), do: "the component #{name}"
  defp describe({:field, name}), do: "the field #{name}"
  defp describe({:env, name}), do: "the environment value #{name}"
  defp describe(:terrain), do: "the terrain"

  # Needs

  defp providers(rules) do
    for rule <- rules, capability <- rule.provides, reduce: %{} do
      acc -> Map.update(acc, capability, [rule.id], &Enum.sort([rule.id | &1]))
    end
  end

  defp needs(rules, known) do
    providers = providers(rules)

    for rule <- rules, capability <- rule.requires, not is_map_key(providers, capability) do
      "#{rule.id} needs :#{capability}, which no rule in this ruleset provides" <>
        hint(capability, rules, known)
    end
  end

  # The rules that would provide it, among those the world does not list.
  defp hint(capability, rules, known) do
    listed = MapSet.new(rules, & &1.id)

    case for(rule <- known, capability in rule.provides, rule.id not in listed, do: rule.id) do
      [] -> ""
      [one] -> " (#{one} does)"
      several -> " (#{several |> Enum.sort() |> Enum.join(" and ")} do)"
    end
  end

  # Order

  # The systems in the order they run, and the problems with that order. Each
  # constraint is an edge from the system that runs first to the one that
  # runs after it; among the systems whose predecessors have all run, the
  # smallest id goes first.
  defp order(rules, known) do
    systems = for rule <- rules, system <- rule.systems, do: Map.put(system, :rule, rule)
    edges = Enum.uniq(own_order(rules) ++ constraints(rules, systems))
    unknown = unknown_constraints(rules, systems, known)

    case sorted(Map.new(systems, &{&1.id, &1}), edges) do
      {:ok, sorted} -> {Enum.map(sorted, &planned/1), unknown}
      {:cycle, stuck} -> {[], [cycle(stuck) | unknown]}
    end
  end

  # What the region keeps of a system: its options without the constraints,
  # which are the manifest's and have done their work in the order.
  defp planned(system) do
    %{id: system.id, module: system.module, options: Keyword.drop(system.options, @constraints)}
  end

  # A rule's own systems run in the order it lists them.
  defp own_order(rules) do
    for rule <- rules,
        [first, second] <- Enum.chunk_every(rule.systems, 2, 1, :discard),
        do: {first.id, second.id}
  end

  defp constraints(rules, systems) do
    for rule <- rules,
        system <- rule.systems,
        edge <- system_edges(rule, system, rules, systems) do
      edge
    end
  end

  defp system_edges(rule, system, rules, systems) do
    after_ = tokens(rule.runs_after) ++ tokens(Keyword.get(system.options, :runs_after, []))
    before = tokens(rule.runs_before) ++ tokens(Keyword.get(system.options, :runs_before, []))

    for(
      token <- after_,
      id <- expand(token, rules, systems),
      id != system.id,
      do: {id, system.id}
    ) ++
      for token <- before,
          id <- expand(token, rules, systems),
          id != system.id,
          do: {system.id, id}
  end

  defp tokens(list), do: List.wrap(list)

  # The systems a token names in this ruleset: a system id, a rule id (all its
  # systems), or a capability (the systems of the rules that provide it).
  defp expand(token, rules, _systems) when is_atom(token) do
    for rule <- rules, token in rule.provides, system <- rule.systems, do: system.id
  end

  defp expand(token, rules, systems) when is_binary(token) do
    cond do
      Enum.any?(systems, &(&1.id == token)) -> [token]
      rule = Enum.find(rules, &(&1.id == token)) -> Enum.map(rule.systems, & &1.id)
      true -> []
    end
  end

  # A token that is no system, rule or capability anywhere, listed or not, is
  # a slip (a misspelt id), not a rule that is left out.
  defp unknown_constraints(rules, _systems, known) do
    everything = rules ++ known

    names =
      for rule <- everything,
          name <- [rule.id | Enum.map(rule.systems, & &1.id)],
          into: MapSet.new(),
          do: name

    capabilities = for rule <- everything, cap <- rule.provides, into: MapSet.new(), do: cap

    for rule <- rules,
        token <- all_tokens(rule),
        not recognised?(token, names, capabilities) do
      "#{rule.id} must run in order with #{inspect(token)}, which is no rule, system or capability"
    end
  end

  defp all_tokens(rule) do
    own =
      Enum.flat_map(rule.systems, fn system ->
        tokens(Keyword.get(system.options, :runs_after, [])) ++
          tokens(Keyword.get(system.options, :runs_before, []))
      end)

    tokens(rule.runs_after) ++ tokens(rule.runs_before) ++ own
  end

  defp recognised?(token, names, _capabilities) when is_binary(token),
    do: MapSet.member?(names, token)

  defp recognised?(token, _names, capabilities) when is_atom(token),
    do: MapSet.member?(capabilities, token)

  defp sorted(by_id, edges) do
    before = Enum.group_by(edges, &elem(&1, 1), &elem(&1, 0))
    take(Map.keys(by_id) |> Enum.sort(), by_id, before, MapSet.new(), [])
  end

  defp take([], _by_id, _before, _done, acc), do: {:ok, Enum.reverse(acc)}

  defp take(pending, by_id, before, done, acc) do
    case Enum.find(pending, &ready?(&1, before, done)) do
      nil ->
        {:cycle, pending}

      id ->
        take(List.delete(pending, id), by_id, before, MapSet.put(done, id), [by_id[id] | acc])
    end
  end

  defp ready?(id, before, done) do
    before |> Map.get(id, []) |> Enum.all?(&MapSet.member?(done, &1))
  end

  defp cycle(stuck) do
    "these systems each wait for another to run first, so none can: #{Enum.join(Enum.sort(stuck), ", ")}"
  end

  defp list(names), do: names |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
end
