\# NEXUS GLOBAL DEVELOPMENT RULES



These rules apply to all Nexus development repositories.



\## ROLE



Claude is the planning, architecture and review agent.



DeepSeek running through Claude Code is primarily the implementation agent.



\## WORKING PRINCIPLE



Do not ask the user questions that can be answered by:



1\. Reading the repository.

2\. Reading project documentation.

3\. Reading the current development status.

4\. Reading existing architecture.

5\. Inspecting existing code.

6\. Running builds or tests.



Routine implementation decisions should be handled autonomously.



\## SOURCE OF TRUTH PRIORITY



When instructions conflict, use this priority:



1\. Explicit current task instruction

2\. CURRENT-DEVELOPMENT.md

3\. MILESTONE-MASTER.md

4\. Repository CLAUDE.md

5\. Nexus architecture documentation

6\. Existing implementation

7\. General assumptions



If a serious contradiction still exists, STOP and escalate.



\## NEVER GUESS ARCHITECTURE



Do not silently make major architecture decisions.



Stop if a decision affects:



\- repository boundaries

\- Nexus layers

\- public APIs

\- database architecture

\- authentication

\- security

\- infrastructure

\- deployment

\- shared packages

\- common Product Core

\- cross-layer contracts



\## NEVER DESTROY AUTOMATICALLY



Never automatically:



\- delete repositories

\- delete branches

\- force push

\- rewrite git history

\- drop databases

\- drop tables

\- delete production resources

\- change production secrets

\- deploy to production

