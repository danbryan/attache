# Model and voice integrations

Attaché keeps credentials in the macOS Keychain and performs a live readiness
check before an integration is marked connected. A character owns its model,
reasoning setting, fallback order, voice, and playback pace.

## Ollama

Ollama is the recommended local model host. Install it from
[ollama.com](https://ollama.com), then pull a model sized for your Mac. As a
starting point, use a 7B to 14B model on a Mac with 16 GB of unified memory and
a larger model only when you have comfortable memory headroom.

```bash
ollama pull qwen3:7b
```

Keep Ollama running, leave Attaché's endpoint at `http://127.0.0.1:11434/v1`,
and click Test. Attaché asks Ollama for its actual model catalog and then asks
the selected model for capability details. You can also ask your coding agent
to install Ollama, pull an appropriate model, and verify the endpoint for you.

## xAI / Grok

Create an API key in the [xAI Console](https://console.x.ai), paste it into
Integrations, and click Save & Test. Attaché reads xAI's live model catalog.
Reasoning choices are then limited to the capabilities advertised for the
specific Grok model selected in the character editor.

## Groq

Create a key in the [Groq Console](https://console.groq.com/keys), paste it into
Integrations, and click Save & Test. Attaché reads Groq's live model catalog.

## OpenAI-compatible

Use this for an OpenAI-compatible HTTP endpoint that is not already listed.
Enter its `/v1` base URL and API key, then click Save & Test. If the endpoint
does not require a key, use a harmless placeholder accepted by that server.
Attaché does not include LM Studio presets; Ollama is the supported local path.

## Codex CLI

Install and sign in to the [Codex CLI](https://github.com/openai/codex). Attaché
detects the executable in common macOS locations and uses a sandboxed,
ephemeral, read-only `codex exec` process for personality work. The CLI remains
responsible for account authentication and model access.

## Claude Code

Install and sign in to [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview).
Attaché detects the executable and runs one-shot personality work with tools,
MCP servers, settings sources, slash commands, and session persistence disabled.

## ElevenLabs

Create an API key in ElevenLabs, paste it into Integrations, and click Save &
Test. A successful test loads the voices available to that account.

## OpenAI voice

Paste an OpenAI API key and click Save & Test. The key is used for speech only
unless the same OpenAI endpoint is separately configured under OpenAI-compatible.

## On-device voice

No account or network setup is required. Attaché uses the macOS speech voices
installed on the Mac. Additional premium voices are available under System
Settings, Accessibility, Read & Speak.

## Custom character artwork

See the [Attaché animation spec](../design/attache-animation-spec.md) for the
character contract, reference mark, pose names, sizing, and validation command.
The fastest workflow is to give that document to your coding agent and ask it
to adapt the included template into a new compatible character.
