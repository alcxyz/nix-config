# Separate agent account

Import `nixosModules.isolatedAgent` and enable `services.isolated-agent` to
create a separate account with its own provider CLIs and T3 server state.
The module does not import the operator's Home Manager profile.
The consumer supplies `package` and `providerPackages` explicitly, so the
generic module does not require a particular overlay or unfree package policy.

The server binds loopback, has no capabilities and cannot elevate privileges.
It starts without browser launch, automatic project creation or printing
headless pairing credentials into the service journal. Pairing is an explicit
operator action.
Its service cannot access home directories, devices or the standard activated
secret directories. Its only persistent writable directory is the account's
home under `/var/lib`. The account has no supplementary groups, sudo grants
or Polkit grants from this module. Other installed authorization policy files
must also pass the consumer's deployed denial probes. Provider authentication is provisioned independently
by the operator, never copied from another account.

`start` defaults to false. A consumer supplies and qualifies its runtime
profile, tool policy, network access and task-specific data interface before
enabling startup. This generic module alone is not a qualified diagnostic
runtime. Account access outside the service also depends on filesystem modes;
verify those under the deployed account before admitting work.

The service uses the locked package set and restarts when its unit changes.
It does not share the operator's independently updated AI stack profile.
