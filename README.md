# Inky 🦑

**Inky** is an Erlang/OTP-based intelligent agent designed for robust home automation, server monitoring, and custom hardware control. 

Built with the resilience of the BEAM virtual machine, Inky aims to provide a more reliable and extensible alternative to projects, integrating directly with local Large Language Models (LLMs) via Ollama to handle complex instructions and decision-making.

## 🚀 Vision

Inky is not just another automation tool; it is a central nervous system for your environment:

- **Home Automation:** Intelligent control of lighting, climate, and appliances through natural language.
- **Hardware Integration:** Direct hooks into hardware control (GPIO, I2C, SPI) for custom electronics projects.
- **Server Orchestration:** Monitoring web services and managing server configurations through a conversational interface.
- **Local Intelligence:** Powered by Ollama (defaulting to Llama 3.2), ensuring your data and control logic stay local.

## 🛠️ Architecture

Inky is built on Erlang/OTP, leveraging its supervision trees and message-passing capabilities for high availability.

- **`inky`**: The core gen_server managing the Telegram bot interaction (via `pe4kin`).
- **`ollama_worker`**: Manages communication with a local Ollama instance, handling tool-calling and conversation history.
- **Tool Dispatch**: A flexible mechanism to map LLM tool calls to local Erlang functions or shell commands.

## 🚦 Current Status

- [x] OTP Application structure.
- [x] Telegram Bot integration (Polling/Webhooks).
- [x] Ollama integration with conversation history.
- [x] Basic Tool Calling (Weather mock implementation).
- [ ] Direct Hardware Control (GPIO/I2C).
	- Using [AtomVM](https://atomvm.org/) to run on microcontrollers.
- [ ] Server Monitoring Hooks.
	- As an erlang node, doing live updating and [HA](https://github.com/wmealing/ha_app)

## 📦 Getting Started

### Prerequisites

- [Erlang/OTP 27+](https://www.erlang.org/downloads)
- [Rebar3](https://rebar3.org/)
- [Ollama](https://ollama.com/) running locally with `llama3.2` (or your preferred model).
  - Probably can hook this directly into whatever model you want.

### Build

```bash
rebar3 compile
```

### Configuration

Copy the example configuration and add your Telegram bot token:

```bash
cp config/sys.config.example config/sys.config
# Edit config/sys.config with your bot name and token
```

### Run

```bash
rebar3 shell
```

## 🤝 Contributing

Inky is an evolving project. If you're interested in hardware control, Erlang, or local AI, feel free to dive in!

---

