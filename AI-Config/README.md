\# Nexus AI-Config



\## Purpose



`AI-Config` is the central configuration and governance location for AI-assisted Nexus development.



The objective is to make Claude Code, DeepSeek, and future development agents operate using a consistent Nexus development process regardless of:



\* which terminal is opened,

\* which Nexus repository is being developed,

\* which development session is running,

\* which implementation agent is being used.



The terminal itself is considered temporary.



The development process must persist through configuration files, repository instructions, and shared development-control files.



\---



\## Core Development Model



Nexus currently uses the following general development workflow:



\*\*Claude\*\*



Planning, architecture, design, review, and major technical decisions.



↓



\*\*Claude Code + DeepSeek\*\*



Repository inspection, implementation, routine technical decisions, builds, tests, fixes, and other execution work.



↓



\*\*Nexus Governance Files\*\*



Control what the implementation agent may do automatically and when it must stop and request a decision.



The objective is not completely uncontrolled autonomous development.



The objective is \*\*controlled autonomous development\*\*.



Routine work should proceed without unnecessary questions.



Architectural, conflicting, destructive, security-sensitive, or out-of-scope decisions must be escalated.



\---



\## Directory



The current directory is:



`C:\\Personal\\DevTools\\AI-Config`



Current files:



\### `deepcode.ps1`



Configures the DeepSeek environment and launches Claude Code using DeepSeek as the implementation model.



The actual API key must not be stored in this file.



Secrets are loaded separately through the Nexus UserSecrets system.



\---



\### `GLOBAL-RULES.md`



Contains rules that apply across Nexus development.



Examples include:



\* responsibilities of development agents,

\* source-of-truth priorities,

\* architectural boundaries,

\* prohibited automatic actions,

\* general Nexus development principles.



These rules should remain repository-independent.



\---



\### `EXECUTION-RULES.md`



Defines work the implementation agent may perform autonomously.



Examples include:



\* reading repository files,

\* searching code,

\* editing files within task scope,

\* creating required files,

\* building,

\* testing,

\* linting,

\* diagnosing failures,

\* fixing implementation errors,

\* repeating build/test/fix cycles.



The objective is to prevent unnecessary interruptions during routine implementation.



\---



\### `ESCALATION-RULES.md`



Defines conditions where autonomous execution must stop.



Examples include:



\* conflicting requirements,

\* architectural decisions,

\* cross-repository conflicts,

\* unclear ownership,

\* destructive changes,

\* production changes,

\* security-sensitive operations,

\* changes outside the assigned scope.



When an escalation occurs, the agent should explain the issue and wait for a decision rather than guessing.



\---



\### `COMPLETION-RULES.md`



Defines when implementation can be considered complete.



Writing code alone does not mean that a task is complete.



Completion may require:



\* successful build,

\* relevant tests,

\* review of changed files,

\* verification that unrelated files were not modified,

\* required development documentation updates,

\* a clear completion report.



\---



\## Secrets



Secrets are deliberately stored outside `AI-Config`.



Central secrets location:



`C:\\Personal\\UserSecrets`



The secrets system contains:



`usersecrets.txt`



Stores local API keys and other development credentials.



`Load-Secrets.ps1`



Loads those secrets into the current process as environment variables.



Development scripts should access secrets through environment variables.



API keys should not be hard-coded into scripts, repositories, prompts, documentation, or source code.



The UserSecrets directory must not be committed to Git.



\---



\## PowerShell Integration



PowerShell `$PROFILE` provides permanent commands such as:



`deepcode`



and:



`start-dev`



This allows development commands to remain available after closing a terminal or restarting the computer.



The PowerShell profile should remain lightweight.



Complex development logic belongs in scripts rather than directly inside `$PROFILE`.



\---



\## DeepCode Flow



The intended DeepCode process is:



PowerShell



↓



`deepcode`



↓



Load central UserSecrets



↓



Run `deepcode.ps1`



↓



Configure DeepSeek



↓



Launch Claude Code



↓



Read Nexus development instructions



↓



Inspect repository and development state



↓



Implement



↓



Build



↓



Test



↓



Fix routine problems automatically



↓



Complete or escalate



\---



\## Repository-Level Instructions



`AI-Config` contains global development rules.



Individual Nexus repositories will contain their own `CLAUDE.md`.



The repository `CLAUDE.md` will provide repository-specific context such as:



\* repository purpose,

\* Nexus layer,

\* repository responsibilities,

\* architectural boundaries,

\* relevant documentation,

\* repository-specific commands,

\* references to the central AI-Config rules.



This avoids copying all global rules into every repository.



\---



\## Development Control



A separate central Development-Control system will manage development state across Nexus repositories.



Its future responsibilities include:



\* active development work,

\* task ownership,

\* simultaneous development sessions,

\* cross-repository conflicts,

\* milestone/task relationships,

\* development status.



This information does not belong inside `AI-Config`.



`AI-Config` answers:



\*\*How should an AI development agent behave?\*\*



Development-Control answers:



\*\*What is currently being developed?\*\*



Repository documentation answers:



\*\*How does this particular Nexus component work?\*\*



\---



\## Design Principle



Nexus development should not depend on remembering instructions from an individual AI conversation or terminal session.



Persistent information should live in persistent files.



Therefore:



\*\*Chat provides decisions and instructions.\*\*



\*\*Files provide persistent context.\*\*



\*\*Agents perform implementation.\*\*



\*\*Git provides source history.\*\*



\*\*Development-Control coordinates simultaneous work.\*\*



\---



\## Current State



The initial AI-Config foundation contains:



\* central global rules,

\* execution rules,

\* escalation rules,

\* completion rules,

\* DeepSeek/Claude Code launcher,

\* centralized external secret loading.



The next stage is repository integration through standardized `CLAUDE.md` files and verification that new development sessions automatically discover and follow the Nexus development process.



