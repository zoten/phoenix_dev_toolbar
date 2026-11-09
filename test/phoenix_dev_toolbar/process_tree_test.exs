defmodule PhoenixDevToolbar.ProcessTreeTest do
  use ExUnit.Case, async: true

  alias PhoenixDevToolbar.ProcessTree

  defp supervisor(children) do
    start_supervised!(%{
      id: make_ref(),
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
      type: :supervisor
    })
  end

  test "a supervisor's counts and children, each with its pid" do
    sup =
      supervisor([%{id: :one, start: {Agent, :start_link, [fn -> 1 end]}}, {Task.Supervisor, []}])

    assert {:ok, %{specs: 2, active: 2, workers: 1, supervisors: 1}, children} =
             ProcessTree.children(sup, 1000)

    assert [%{id: ":one", type: :worker, pid: agent} | _rest] = Enum.sort_by(children, & &1.id)
    assert is_pid(agent)
    assert Enum.any?(children, &(&1.type == :supervisor))
  end

  test "a DynamicSupervisor above the cap gives its counts only" do
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    for _ <- 0..ProcessTree.max_children(),
        do: {:ok, _pid} = DynamicSupervisor.start_child(sup, {Agent, fn -> 1 end})

    assert {:ok, %{specs: 201}, :too_many} = ProcessTree.children(sup, 1000)
  end

  test "a simple_one_for_one supervisor above the cap gives its counts only" do
    sup =
      start_supervised!(%{
        id: :sofo,
        start: {:supervisor, :start_link, [PhoenixDevToolbar.SofoSupervisor, :ok]},
        type: :supervisor
      })

    for _ <- 0..ProcessTree.max_children(), do: {:ok, _pid} = :supervisor.start_child(sup, [])

    assert {:ok, %{specs: 1, active: 201}, :too_many} = ProcessTree.children(sup, 1000)
  end

  test "a GenServer is not a supervisor, and is never asked" do
    agent = start_supervised!({Agent, fn -> 1 end})

    refute ProcessTree.supervisor?(agent)
    assert ProcessTree.children(agent, 1000) == {:error, :not_supervisor}
    assert Process.info(agent, :message_queue_len) == {:message_queue_len, 0}
  end

  test "a busy supervisor times out" do
    sup = supervisor([])
    :ok = :sys.suspend(sup)

    try do
      assert ProcessTree.children(sup, 50) == {:error, :timeout}
    after
      :sys.resume(sup)
    end
  end

  test "applications: the host's first, each with its top supervisor" do
    assert {:ok, apps} = ProcessTree.applications(1000)

    toolbar = Enum.find(apps, &(&1.name == :phoenix_dev_toolbar))
    assert %{group: :host, supervisor: pid} = toolbar
    assert pid == Process.whereis(PhoenixDevToolbar.Supervisor)

    assert %{group: :otp} = Enum.find(apps, &(&1.name == :kernel))
    assert %{group: :elixir} = Enum.find(apps, &(&1.name == :elixir))
    assert hd(apps).group == :host
  end
end
