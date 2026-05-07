#!/usr/bin/env python3
"""Reconstructs the buggy state: adds trail title generation code
that was present on feat/trails before the removal.
"""
import os
import sys

repo_dir = sys.argv[1] if len(sys.argv) > 1 else "/workspace/repo"

# ---------------------------------------------------------------------------
# 1. Create cmd/entire/cli/summarize/trail_title.go
# ---------------------------------------------------------------------------
trail_title_content = '''package summarize

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/entireio/cli/cmd/entire/cli/agent"
	"github.com/entireio/cli/cmd/entire/cli/agent/types"
	"github.com/entireio/cli/redact"
)

// trailTitlePromptTemplate is the prompt used to generate trail titles and descriptions.
//
// Security note: The transcript is wrapped in <transcript> tags to provide clear boundary
// markers. This helps contain any potentially malicious content within the transcript.
const trailTitlePromptTemplate = `Analyze this development session transcript and generate a title and description.

<transcript>
%s
</transcript>

Return a JSON object:
{
  "title": "Short imperative title (max 80 chars)",
  "body": "1-3 sentence description of what was accomplished and why"
}

Guidelines:
- Title: imperative mood, captures core intent (e.g. "Add user authentication flow")
- Body: explain the "what" and "why", not the "how"
- Return ONLY the JSON object`

// trailTitleModel is the model hint for trail title generation.
// Haiku is fast (~1-2s) and cheap — trail titles are simple tasks.
const trailTitleModel = "haiku"

// TrailTitleResult contains the LLM-generated title and body for a trail.
type TrailTitleResult struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

// GenerateTrailTitle generates a title and description for a trail using the agent's
// text generation capability. Returns (nil, nil) if the agent doesn't support text generation.
func GenerateTrailTitle(ctx context.Context, transcriptBytes []byte, filesTouched []string, agentType types.AgentType) (*TrailTitleResult, error) {
	// Get the active agent and check if it implements TextGenerator
	ag, err := agent.GetByAgentType(agentType)
	if err != nil {
		return nil, fmt.Errorf("agent not found: %w", err)
	}
	gen, ok := ag.(agent.TextGenerator)
	if !ok {
		// Agent does not support text generation: treat as non-fatal and return no result.
		return nil, nil //nolint:nilnil // nil result signals "not supported", not an error
	}

	// Build condensed transcript (reuse existing infrastructure)
	condensed, err := BuildCondensedTranscriptFromBytes(redact.AlreadyRedacted(transcriptBytes), agentType)
	if err != nil {
		return nil, fmt.Errorf("failed to parse transcript: %w", err)
	}
	if len(condensed) == 0 {
		return nil, errors.New("transcript has no content")
	}

	input := Input{Transcript: condensed, FilesTouched: filesTouched}
	transcriptText := FormatCondensedTranscript(input)

	// Build prompt and call agent's TextGenerator
	prompt := fmt.Sprintf(trailTitlePromptTemplate, transcriptText)
	rawResult, err := gen.GenerateText(ctx, prompt, trailTitleModel)
	if err != nil {
		return nil, fmt.Errorf("text generation failed: %w", err)
	}

	// Parse JSON response (handle markdown code blocks)
	cleaned := extractJSONFromMarkdown(rawResult)
	var result TrailTitleResult
	if err := json.Unmarshal([]byte(cleaned), &result); err != nil {
		return nil, fmt.Errorf("failed to parse trail title JSON: %w", err)
	}

	return &result, nil
}
'''

trail_title_path = os.path.join(repo_dir, "cmd/entire/cli/summarize/trail_title.go")
os.makedirs(os.path.dirname(trail_title_path), exist_ok=True)
with open(trail_title_path, "w") as f:
    f.write(trail_title_content)
print("Created trail_title.go")

# ---------------------------------------------------------------------------
# 2. Modify manual_commit_hooks.go
# ---------------------------------------------------------------------------
hooks_path = os.path.join(repo_dir, "cmd/entire/cli/strategy/manual_commit_hooks.go")
with open(hooks_path) as f:
    content = f.read()
    lines = content.split("\n")

# 2a. Add "trail" and "summarize" imports after the stringutil import
# Main branch has:      "github.com/entireio/cli/cmd/entire/cli/stringutil"
# We need to add after: "github.com/entireio/cli/cmd/entire/cli/summarize"
#                       "github.com/entireio/cli/cmd/entire/cli/trail"
new_lines = []
for line in lines:
    new_lines.append(line)
    if line.strip() == '"github.com/entireio/cli/cmd/entire/cli/stringutil"':
        new_lines.append('\t"github.com/entireio/cli/cmd/entire/cli/summarize"')
        new_lines.append('\t"github.com/entireio/cli/cmd/entire/cli/trail"')

content = "\n".join(new_lines)

# 2b. Add call to generateTrailTitleForTrail inside condenseAndUpdateState
# Find:   return true
#         }
# (end of condenseAndUpdateState)
# Add call before "return true"

trail_call = """\t// Optionally generate trail title (best-effort)
\tgenerateTrailTitleForTrail(nil, "", result.Transcript, result.FilesTouched, state.AgentType)"""

# Find the end of condenseAndUpdateState
# We look for the pattern: logging.Info(...) ... return true
lines = content.split("\n")
new_lines = []
in_condense = False
for i, line in enumerate(lines):
    new_lines.append(line)
    # After "return true" in condenseAndUpdateState, add the function
    if line.strip() == "return true":
        # Check context: look back to see if we're in condenseAndUpdateState
        context_start = max(0, i - 20)
        context = "\n".join(lines[context_start:i])
        if "logging.Info(logCtx, \"session condensed\"" in context:
            # Insert call before return true, but this is after the logging
            # Actually, insert BEFORE return true
            new_lines.insert(-1, trail_call)

content = "\n".join(new_lines)

# 2c. Append the generateTrailTitleForTrail function
gen_func = '''
// generateTrailTitleForTrail uses the agent's text generation capability
// to generate a proper title and description for the trail. Best-effort: silently
// returns on any error.
func generateTrailTitleForTrail(store *trail.Store, trailID trail.ID, transcriptBytes []byte, filesTouched []string, agentType types.AgentType) {
	if !settings.IsSummarizeEnabled(context.Background()) {
		return
	}

	logCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	logCtx = logging.WithComponent(logCtx, "trail-title")
	result, err := summarize.GenerateTrailTitle(logCtx, transcriptBytes, filesTouched, agentType)
	if err != nil {
		logging.Debug(logCtx, "trail title generation skipped",
			slog.String("error", err.Error()))
		return
	}

	//nolint:errcheck,gosec // best-effort: trail title generation is non-critical
	if store != nil && trailID != "" {
		store.Update(context.Background(), trailID, func(m *trail.Metadata) {
			if result.Title != "" {
				m.Title = result.Title
			}
			if result.Body != "" {
				m.Body = result.Body
			}
		})
	}
}'''

content = content + gen_func

with open(hooks_path, "w") as f:
    f.write(content)
print("Modified manual_commit_hooks.go: added imports, call site, and function")
