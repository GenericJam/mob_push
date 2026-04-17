defmodule MobPushTest do
  use ExUnit.Case

  test "send/3 returns error for unknown platform" do
    assert {:error, {:unknown_platform, :blackberry}} =
             MobPush.send("token", :blackberry, %{title: "Hi", body: "World"})
  end

  test "send!/3 raises on error" do
    assert_raise RuntimeError, ~r/unknown_platform/, fn ->
      MobPush.send!("token", :blackberry, %{title: "Hi", body: "World"})
    end
  end
end
