defmodule Avwe.Hooks.Play do
  @moduledoc """
  The agent layer's part of starting a region again.

  A body is held by a session's lease, and sessions end with their world without
  releasing (`Avwe.Session`), so a world that starts again, or a region that
  crashed after its world stopped, finds holders written on bodies that nobody
  holds any more. Each of them is released at the next step, by an intent
  submitted and journaled like a session's own, so replay gives the same; the
  routine then takes the body. A body whose holder is a live session of this
  world (a region that crashed and came back while its sessions ran) is left
  alone.
  """

  @behaviour Avwe.Hooks

  alias Avwe.{Intent, Region}

  @impl Avwe.Hooks
  def on_resume(region, %{world: world}) do
    world_pid = Avwe.World.whereis(world)
    pending = Region.pending(region)

    for body <- Region.with_components(region, [:control]),
        holder = holder_after(Region.get(region, body, :control).holder, pending, body),
        holder != nil,
        not leased?(world, world_pid, body) do
      ref = "resume-release-#{System.unique_integer([:positive])}"
      Intent.new(body, :release, ref: ref, controller: holder)
    end
  end

  # Who will hold the body once the lease intents already waiting for the
  # next step (journaled before the world stopped) are applied, in order.
  defp holder_after(holder, pending, body) do
    Enum.reduce(pending, holder, fn
      %Intent{body: ^body, verb: :control, controller: controller}, _held -> controller
      %Intent{body: ^body, verb: :release}, _held -> nil
      _other, held -> held
    end)
  end

  defp leased?(world, world_pid, body) do
    match?(
      [{_session, {_controller, ^world_pid}}],
      Registry.lookup(Avwe.Registry, {:lease, world, body})
    )
  end
end
