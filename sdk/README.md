# Moon Browser plugin SDK

The first host API is protocol 2. Native executable plugins use this transport. Lua browser plugins will use the same capabilities through a Lua adapter.

- `moon_plugin.zig` contains types and a Zig 0.17.1 stdio client.
- `plugin.schema.json` describes the plugin manifest.
- `tests/plugin_contract_client.zig` in the repository is a host contract test that uses the SDK. It runs during the browser smoke test.

Import `moon_plugin.zig` as the `moon_plugin` module and link libc. The client uses UTF-8 JSON-RPC 2.0 over stdin and stdout. Initialize a `Client` with an arena scoped to one plugin invocation, call `initialize()`, receive an invocation and use `call()` for browser methods. Reply to a command with `reply()` and exit. Exit after handling an event notification.

[Protocol and permission reference](https://docs.browser.moonl.cloud/api.html)
