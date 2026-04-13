# Snapshot Local Restore - Context Summary

## Problem
The original `snapshot-local-restore.php` mu-plugin tried to manually extract and import SQL files from Snapshot Pro backups. This approach failed because:
1. Snapshot Pro uses a custom SQL format with `# ---------- end_snapshot_statement ----------` separators
2. It didn't restore WordPress files (wp-content, plugins, themes)
3. It didn't leverage Snapshot Pro's existing restore functionality

## Solution
Rewrote the plugin to use Snapshot Pro's internal AJAX API directly:

1. **`snapshot-auto-restore.php`** (v1.0.1)
   - Simply enables `SNAPSHOT4_MANUAL_RESTORE_MODE = true`
   - Enables Snapshot Pro's manual restore mode that skips cloud download

2. **`snapshot-local-restore.php`** (v3.0.0)
   - **Prepare**: Copies backup zip to `wp-content/uploads/snapshot-backups/locks/<backup_id>/`
   - **Lock file**: Creates JSON with `backup_id`, `restore_type`, and `stage`
   - **API trigger**: Calls `\WPMUDEV\Snapshot4\Controller\Ajax\Restore::json_process_restore()` directly
   - **Stage processing**: Loops through stages (files → tables → finalize) until completion

## Key Findings
- Snapshot Pro's manual restore mode (`SNAPSHOT4_MANUAL_RESTORE_MODE`) allows restoring without cloud
- The AJAX endpoint `wp_ajax_snapshot-process_restore` handles all restore stages
- Lock file must be in `wp-content/uploads/snapshot-backups/locks/<backup_id>.json`
- Backup zip must be in the same directory as the lock file: `<backup_id>.zip`

## Backup File Pattern
- `cognitis.cloud_20260412_0748_c53a90fbd70f.zip` → backup_id: `cognitiscloud_20260412_0748_c53a90fbd70f`

## Files Modified
- `mu-plugins/snapshot-local-restore.php` - Complete rewrite (v1.0.0 → v3.0.0)
- `mu-plugins/snapshot-auto-restore.php` - Simplified (v1.0.0 → v1.0.1)
- `AGENTS.md` - Added Snapshot Pro Local Restore section
- `README.md` - Added Snapshot Pro Local Restore section