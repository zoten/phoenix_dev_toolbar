# Test fixtures that raise or throw on purpose: `:error_handling` reports them as
# never returning. Ignored by file and warning type only, never by line.
[
  {"test/support/demo_boom_plug.ex", :no_return},
  {"test/support/demo_throw_plug.ex", :no_return},
  {"test/support/fragile_panel.ex", :no_return},
  {"test/support/message_raising_error.ex", :no_return},
  {"test/support/mount_boom_panel.ex", :no_return},
  {"test/support/raising_plugin.ex", :no_return},
  {"test/support/throwing_id_plugin.ex", :no_return}
]
