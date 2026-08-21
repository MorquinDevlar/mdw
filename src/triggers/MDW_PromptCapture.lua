-- MDW Prompt Capture Trigger
-- Captures the MUD prompt and displays it in the prompt bar.
-- Respects mdw.config.usePromptTrigger so a game can drive the prompt bar itself.
if mdw and mdw.capturePrompt and mdw.config and mdw.config.usePromptTrigger ~= false then
	mdw.capturePrompt()
end
