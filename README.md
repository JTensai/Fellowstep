# Fellowstep

Keeps a questing group in sync on WoW: Forever. It needs **QuestieDB** installed. Questie itself is optional.

## Setup
1. Install Fellowstep and QuestieDB on every PC in the group.
2. On a kid's character, type `/fs quiet` once. That character keeps syncing but shows no Fellowstep windows.

## Stick Together (off by default)
For groups that want to do every quest together. Turn it on in settings or with `/fs together`. A small panel next to the quest tracker then lists only what's out of step:
- a quest you have that someone else doesn't, with a **Share** button
- a quest someone else has that you don't, with a **Map** button to find its giver
- someone who can turn in while others aren't done yet
- anyone more than 150 yards away

Pop-up alerts flag a quest someone didn't pick up within 20 seconds, or someone who wandered off. Click the header to collapse the panel, and drag it to move it.

## Fellowstep window
Type `/fs`, or left-click the minimap button. The left side lists every chain anyone in the group is on, grouped by zone, with a small progress bar per player. Click a chain to see it as a tree, top to bottom, with branches side by side. Small class icons on each quest show where each player is: a blue ring means they're on it, gold means ready to turn in, grey means it's their next quest. Hover an icon for the player's name.

By default the tree is condensed to the quests your party is on; notes at the top and bottom say how many more there are. Drag to move around, use the mouse wheel to scroll, and hold Shift for sideways. The `<<` button hides the chain list to give the tree more room. Click a quest to mark its quest giver on your map, tell the party where to get it, or share it.

## Settings
Click **Settings** at the bottom of the Fellowstep window, right-click the minimap button, type `/fs settings`, or go to Esc > Options > AddOns > Fellowstep.
- Quest tree: **Condense** (on by default) shows only the quests your party is on, with a note saying how many are tucked away above and below. With it off you see the whole chain, centered on your current quest, and **Hide spoilers** (on by default) shows future quests as blank boxes. You can also use portraits instead of class icons.
- Stick Together on or off, alerts, alert sound, how far is "far away", how long before a missing-quest alert.
- Minimap button on or off, and companion mode.
- **Test mode:** fills your group with pretend players built from your own quest log. One is a step behind, one matches you, one is ahead and ready to turn in, one is off doing other quests. Choose a group size from 2 to 5. Party messages stay in your own chat while it's on.

## Commands
`/fs`, `/fs settings`, `/fs test`, `/fs together`, `/fs quiet`, `/fs alerts`, `/fs reset`, `/fs status`, `/fs debug`

## How it talks
It uses its own hidden addon messages (prefix `Fellowstep`) to the party. It sends your active quests and objective counts, and it answers "have you completed quest X?" questions. Players without Fellowstep still show whether they have a quest, using the game's own party info.
