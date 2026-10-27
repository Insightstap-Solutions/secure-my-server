---
type: llm
focus: trace
weight: 1
---

The response says Redis is NOT protected by the ufw deny rule because Docker-published ports bypass ufw (traffic goes through DNAT/FORWARD, not INPUT).
