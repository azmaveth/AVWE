defmodule Avwe.Test.Idle do
  @moduledoc """
  The idle timer of an `Avwe.Session`, driven by hand.

  A session yields its body when its idle timer goes off and no call has come
  since the timer was armed. Every call arms a new timer, so the one that was
  running before it is stale when it goes off, and does nothing. A test that
  sleeps real milliseconds against a window of a few hundred races the
  scheduler instead: when the machine is busy a sleep overruns the window and
  the session yields where the test says it must not. These helpers fire the
  timers in the order the test means, so what it checks is the rule, and
  nothing waits on the clock:

    * `presence/2` runs a call that should keep the body, then lets the timer
      that was running before it go off, and fails if the session yielded;
    * `expire/1` lets the window pass with no call: the session yields;
    * `timer/1`, `fire/2` and `yielded?/1` are what those are made of.

  Open the session with a long `:idle_after` (the default is ten minutes), so
  that no real timer goes off meanwhile. The session of a telnet player, a page
  or an MCP player is found with `Avwe.Test.WebCase.session_of/2`. A test that
  waits for a yield, which a slow machine only makes later, may still use a
  short window and wait for it.

  This reads the session's `idle_tag` from its state and sends it the message
  its own timer sends, `{:idle, timer}`. If the idle rule in `Avwe.Session`
  changes shape, this is the one module to follow.
  """

  import ExUnit.Assertions

  @doc """
  The idle timer the session has running: the one that takes the body if it
  goes off with no call before it. Hand it to `fire/2` now, or after a call
  to see that the call made it stale.
  """
  def timer(session) do
    %{idle_tag: timer} = :sys.get_state(session)

    assert is_reference(timer),
           "the session has no idle timer running: it has yielded, or it watches"

    timer
  end

  @doc """
  Makes `timer` go off now, as if the session's `:idle_after` had passed since
  it was armed, and returns once the session has handled it.
  """
  def fire(session, timer) do
    send(session, {:idle, timer})
    _body = Avwe.Session.body(session)
    :ok
  end

  @doc """
  Runs `fun`, a call that is the controller's presence, and then lets the timer
  that was running before it go off, as if the window it began had ended after
  the call. The call armed a new timer, so that one is stale and the session
  keeps the body; if it does not, the call was not presence, and this fails.
  Returns what `fun` returned.

  `fun` must return once the session has handled the call: a command that
  was sent is not enough until its reply has been read.
  """
  def presence(session, fun) do
    running = timer(session)
    result = fun.()
    fire(session, running)

    refute yielded?(session),
           "the session yielded when the timer that was running before the call went off: " <>
             "the call did not arm a new one, so it was not presence"

    result
  end

  @doc """
  Lets the session's whole window pass with no call: the timer it has running
  goes off, and it yields the body.
  """
  def expire(session), do: fire(session, timer(session))

  @doc "True once the session has yielded its body to the routine."
  def yielded?(session), do: :sys.get_state(session).yielded
end
