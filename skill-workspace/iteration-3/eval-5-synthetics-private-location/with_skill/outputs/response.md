# Setting Up a Synthetics Private Location on Local Kibana

This is already set up for you. Your tmux session has a `scripts` window with the left pane (pane 0) pre-populated with the command — you just need to press Enter.

## Step 1: Verify Kibana is running

```bash
~/dev-start.sh status
```

Make sure both ES and Kibana show as `up`.

## Step 2: Run the synthetics setup

Switch to your tmux session's `scripts` window:
- **Ctrl-a w** → select `scripts`
- The left pane already has `run-data synthetics` ready to go — just press **Enter**

That's it. The command:
- Reads your Kibana port and ES credentials from `config/kibana.dev.yml` automatically
- Waits for Kibana to be ready
- Creates the private location using the Fleet Server policy already configured in your `kibana.dev.yml` (`fleet-server-policy` via `xpack.fleet.agentPolicies`)

If you prefer to run it from any terminal:

```bash
run-data synthetics
```

## Important notes

- **Local ES only** — remote ES clusters already have managed locations available in the Synthetics UI. The command will tell you this and exit if it detects remote ES.
- **Fleet policy is pre-configured** — your `kibana.dev.yml` template already provisions the Fleet Server agent policy, Fleet Server host, ES output, and the Fleet Server package. No manual Fleet setup needed.
- **Uses `elastic` superuser** — don't use `kibana_system_user`, it lacks the required permissions.

## Troubleshooting

If the private location creation fails:
1. Verify Kibana is ready: `~/dev-start.sh status`
2. Check you're on local ES (not `--remote`)
3. Confirm `config/kibana.dev.yml` has the `xpack.fleet.agentPolicies` section
4. Check the output in the scripts pane for error details
