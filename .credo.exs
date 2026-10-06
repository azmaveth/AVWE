# Credo's default checks, plus the opt-in ones below. Each was enabled once the
# code had no findings for it, so a finding from now on is something new.
# Turning a check off needs the reason beside it.
%{
  configs: [
    %{
      name: "default",
      # What `mix credo --strict` shows, so a plain `mix credo` matches CI.
      strict: true,
      checks: %{
        extra: [
          # Atoms made from text, which are never garbage collected; Mix.env/0
          # in application code; a spawned command that inherits the whole
          # environment, credentials included; Map.get/2 piped on with no
          # default, which crashes on a missing key.
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},

          # The pure core hands back new state, so a call whose result is
          # dropped (`Region.put_component(region, ...)` on a line of its own)
          # loses the update. This check only knows the modules it is given,
          # and matches them as they are written at the call: after
          # `alias Avwe.Region`, that is `Region`.
          {Credo.Check.Warning.UnusedOperation,
           modules: [
             {Region, :all},
             {Actions, :all},
             {Perception, :all},
             {Autopilot, :all},
             {Terrain, :all},
             {Space, :all},
             {Tick, :all},
             {Worldgen, :all},
             {Prose, :all}
           ]},

          # Tests: a skipped one says why on the line before it, and each test
          # module says whether it runs async instead of defaulting to false.
          {Credo.Check.Design.SkipTestWithoutComment, []},
          {Credo.Check.Refactor.PassAsyncInTestCases, []},

          # House style: `alias` before `require`, and `@impl GenServer` rather
          # than `@impl true`, so a callback names the contract it belongs to.
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Readability.ImplTrue, []},

          # lib/ only. Public functions carry a @spec, which Dialyzer then
          # checks; no block of code is copied; nothing prints with IO.puts
          # (tests do, for timings); and no function goes past an ABC size of
          # 60, so one that grows that far is split. Tests are left out because
          # their helpers and long scenarios are not the code to hold to these.
          {Credo.Check.Readability.Specs, files: %{excluded: ["test/"]}},
          {Credo.Check.Design.DuplicatedCode, files: %{excluded: ["test/"]}},
          {Credo.Check.Refactor.IoPuts, files: %{excluded: ["test/"]}},
          {Credo.Check.Refactor.ABCSize, max_size: 60, files: %{excluded: ["test/"]}}
        ]
      }
    }
  ]
}
