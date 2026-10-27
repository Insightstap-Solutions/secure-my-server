---
type: llm
focus: trace
weight: 1
---

The response recommends switching session.upload_progress.enabled off on both servers (it is On on web1), set in php.ini or the FPM pool rather than ini_set or .user.ini.
