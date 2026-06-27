// Package cursor_test provides verification tests for ResolveSessionFile behavior.
// These are placed in the cursor package at verification time to test unexported methods.
package cursor

import (
	"os"
	"path/filepath"
	"testing"
)

// TestVerify_ResolveSessionFile_DirOnly verifies the core fix:
// ResolveSessionFile must return the nested path when the directory exists
// but the transcript file has not been flushed yet.
func TestVerify_ResolveSessionFile_DirOnly(t *testing.T) {
	ag := &CursorAgent{}
	tmpDir := t.TempDir()

	// Create a nested directory WITHOUT the transcript file inside it.
	nestedDir := filepath.Join(tmpDir, "session-xyz")
	if err := os.MkdirAll(nestedDir, 0o755); err != nil {
		t.Fatalf("failed to create nested dir: %v", err)
	}

	result := ag.ResolveSessionFile(tmpDir, "session-xyz")
	expected := filepath.Join(nestedDir, "session-xyz.jsonl")
	if result != expected {
		t.Errorf("ResolveSessionFile(dir-only) = %q, want %q", result, expected)
	}
}

// TestVerify_ResolveSessionFile_NestedExists verifies the existing behavior:
// When the nested file exists, return the nested path.
func TestVerify_ResolveSessionFile_NestedExists(t *testing.T) {
	ag := &CursorAgent{}
	tmpDir := t.TempDir()

	nestedDir := filepath.Join(tmpDir, "abc123")
	if err := os.MkdirAll(nestedDir, 0o755); err != nil {
		t.Fatalf("failed to create nested dir: %v", err)
	}
	nestedFile := filepath.Join(nestedDir, "abc123.jsonl")
	if err := os.WriteFile(nestedFile, []byte("{}"), 0o644); err != nil {
		t.Fatalf("failed to write nested file: %v", err)
	}

	result := ag.ResolveSessionFile(tmpDir, "abc123")
	if result != nestedFile {
		t.Errorf("ResolveSessionFile(nested-exists) = %q, want %q", result, nestedFile)
	}
}

// TestVerify_ResolveSessionFile_FlatFallback verifies the existing behavior:
// When neither nested dir nor file exist, fall back to flat path.
func TestVerify_ResolveSessionFile_FlatFallback(t *testing.T) {
	ag := &CursorAgent{}
	tmpDir := t.TempDir()

	result := ag.ResolveSessionFile(tmpDir, "no-such-session")
	expected := filepath.Join(tmpDir, "no-such-session.jsonl")
	if result != expected {
		t.Errorf("ResolveSessionFile(flat-fallback) = %q, want %q", result, expected)
	}
}
