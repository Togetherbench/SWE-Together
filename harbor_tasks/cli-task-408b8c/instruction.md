in common.go we have a GetWorkTreePath function that i think shoudl be able to be acached like RepoRoot and GetCommonDir functions. Look at thos and update the GetworktreePath function:



// GetWorktreePath returns the absolute path to the current worktree root.
// This is the working directory path, not the git directory.
func GetWorktreePath() (string, error) {
    ctx := context.Background()
    cmd := exec.CommandContext(ctx, "git", "rev-parse", "--show-toplevel")
    output, err := cmd.Output()
    if err != nil {
        return "", fmt.Errorf("failed to get worktree path: %w", err)
    }
    return strings.TrimSpace(string(output)), nil
}
