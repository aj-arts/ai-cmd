# ai-cmd

`ai-cmd` is an Oh My Zsh plugin that turns natural-language requests into shell commands using OpenRouter's Responses API.

## Requirements

- [Oh My Zsh](https://ohmyz.sh/)
- `zsh`
- `curl`
- An `OPENROUTER_API_KEY`

## Install In Oh My Zsh

Clone the repository into your Oh My Zsh custom plugins directory:

```sh
git clone https://github.com/aj-arts/ai-cmd.git "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/ai-cmd"
```

Add `ai-cmd` to the `plugins=(...)` list in your `~/.zshrc`:

```sh
plugins=(
  git
  ai-cmd
)
```

Set your OpenRouter API key in `~/.zshrc`:

```sh
export OPENROUTER_API_KEY="your_api_key_here"
```

Reload your shell:

```sh
source ~/.zshrc
```

## Update

Pull the latest changes from the same directory you cloned into, then reload `zsh` so the updated plugin loads:

```sh
cd "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/ai-cmd"
git pull
source ~/.zshrc
```

If you installed the repo somewhere else, run `git pull` in that directory instead. For shells that were already open, either run `source ~/.zshrc` in each one or start a new terminal so they pick up the updated plugin.

## Usage

After installation, the default trigger is a prompt line that starts with `##`. Type a request like this and press Enter:

```sh
## find the ten largest files here
```

`ai-cmd` will replace that line with the generated shell command so you can review or edit it before running it.

You can also generate a command explicitly from a prompt:

```sh
aicmd "find the ten largest files here"
```

In interactive `zsh`, the generated command is inserted into your prompt so you can review or edit it before running it.

## Trigger Options

### Option 1: Change The Comment-Style Prefix

The default prefix is `##` so plain `#` comments still behave normally. If you want a different prefix, you can change it:

```sh
export AICMD_TRIGGER_PREFIX="##"
```

If you want to disable the Enter-triggered comment flow entirely:

```sh
export AICMD_ACCEPT_LINE_TRIGGER=0
```

### Option 2: Explicit Keybinding

Bind the widget to a shortcut in `~/.zshrc`:

```sh
bindkey '^X^A' aicmd-widget
```

Then reload your shell with `source ~/.zshrc`.

With that binding in place, type a natural-language request at the prompt and press `Ctrl-X Ctrl-A` to replace the buffer with the generated command.

## Configuration

Optional environment variables:

```sh
export AICMD_MODEL="google/gemini-3-flash-preview"
export AICMD_TARGET_SHELL="auto"
export AICMD_TIMEOUT="30"
export AICMD_ACCEPT_LINE_TRIGGER="1"
export AICMD_TRIGGER_PREFIX="##"
```

## Built-In Commands

- `aicmd "<prompt>"` generates a command from a natural-language request.
- `aicmd-buffer` replaces the current ZLE buffer and is intended for widget use.
- `aicmd-help` shows usage information.
