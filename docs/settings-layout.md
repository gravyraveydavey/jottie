# Settings layout

Settings has four main pages. Each page keeps related controls together; Recording, Summaries and Integrations use a section picker so connection forms and specialist controls do not accumulate into one long page.

| Page | Sections and controls |
| --- | --- |
| General | Theme, window language, Dock/menu-bar visibility, launch window, start at login, your microphone speaker name |
| Recording → Capture | Microphone/system audio permissions, automatic recording from call activity, audio source and echo removal |
| Recording → Transcription | Local recognizer, meeting language, live transcript, local voice separation and transcript naming |
| Recording → Voice learning | Remember voices, suggestion/automatic assignment, re-evaluate saved evidence, erase voice evidence |
| Recording → Models | Download, repair and delete local speech/separation models |
| Summaries → Automation | Opt-in Codex analysis, model/effort, summary updates and folder context updates |
| Summaries → Prompts (Advanced) | Meeting/folder prompts, preview and reset |
| Integrations → Calendars | Access, calendar selection, reading invitation context, starting recordings from calendar events |
| Integrations → BambooHR | Company/key, directory sync/enrichment/disconnect; directory aliases in Advanced |
| Integrations → Codex | Installation/sign-in status, check/test connection, executable override in Advanced |
| Integrations → Microsoft | Tenant/client registration and sign-in; destinations remain per folder |
| Integrations → MCP | Read-only local assistant connection and copied configuration |

The shared **Advanced** switch is off by default and remembered on this Mac. It also gates speaker-tab voice debugging. It reveals numeric voice tuning, speech filters, automatic-recording delays/limits/app lists, capture folder/configuration tools, the after-session hook, custom prompts/model IDs and folder refresh cadence. Switching it off changes visibility only: it does not reset saved or unsaved values. Normal speaker rows retain useful attribution source badges and reviewable voice suggestions without raw scores/window diagnostics.

Capture settings still save individually (Apply for text fields) and report restart requirements. Library/voice/Codex/calendar-selection changes use **Save settings**. Changing Basic/Advanced is a presentation preference and needs no Save.

## Removing a calendar match

Open a recording's **Speakers → Meeting sources → Remove calendar match**, or use the same action inside the event picker. This clears the invitation, invitees and derived directory context. The explicit no-match override survives source rescans, including changed transcripts. An exact invitation-derived title falls back to the recording date; independent titles, transcript content, manual speaker names and analysis revisions remain intact. A retained summary using the removed context can be regenerated explicitly. Selecting a different event later restores invitation context normally.
