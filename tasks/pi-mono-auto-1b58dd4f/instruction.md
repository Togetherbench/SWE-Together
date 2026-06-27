i had you write a trivial extension in another session to .pi/extensions/test.ts (no longer there). it registered a command /test that would use ui.notify().

when i started the session, test.ts didn'T exist yet, you created it. then i did /reload. the /test command got registered, but running it did not show the ui notification. can you figure out why that is?
