//! 接收落盘临时区——应用独占的隐藏子目录 + 同文件系统原子改名。
//!
//! 未完成字节写在最终文件同父目录的 `.handysend-temp/` 中，完成后
//! `rename` 到最终路径。临时区是本应用独占的命名空间，清理时只枚举
//! 该目录，不触碰用户文件或已交付文件。旧版本目录 `.handysend-upload-part/`
//! 作为 legacy 名称 best-effort 清理。

use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// 当前临时区目录名。
pub const TEMP_DIR_NAME: &str = ".handysend-temp";

/// 旧版本临时区目录名，仅用于清理残留。
pub const LEGACY_TEMP_DIR_NAMES: &[&str] = &[".handysend-upload-part"];

/// 最终路径对应的临时目录。
pub fn temp_dir_for(final_path: &Path) -> PathBuf {
    final_path
        .parent()
        .unwrap_or_else(|| Path::new(""))
        .join(TEMP_DIR_NAME)
}

/// 最终路径对应的临时文件路径（同名文件，父目录为临时区）。
pub fn temp_path_for(final_path: &Path) -> PathBuf {
    let name = final_path
        .file_name()
        .map(|name| name.to_os_string())
        .unwrap_or_default();
    temp_dir_for(final_path).join(name)
}

/// 字符串路径便捷入口。
pub fn temp_dir(final_path: &str) -> PathBuf {
    temp_dir_for(Path::new(final_path))
}

/// 字符串路径便捷入口。
pub fn temp_path(final_path: &str) -> PathBuf {
    temp_path_for(Path::new(final_path))
}

/// 原子提交：把临时文件改名为最终文件（同一文件系统内）。
pub fn commit(temp: &Path, final_path: &Path) -> std::io::Result<()> {
    std::fs::rename(temp, final_path)
}

/// 删除临时文件，并尝试移除已空的临时目录。
pub fn remove_temp_file(path: &Path) {
    let _ = std::fs::remove_file(path);
    if let Some(dir) = path.parent() {
        let _ = std::fs::remove_dir(dir);
    }
}

/// 清理指定临时目录中的遗留文件（只处理直接子文件，目录非空时保留）。
pub fn cleanup_dir(dir: &Path, active: &HashSet<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_file() && !active.contains(&path) {
            let _ = std::fs::remove_file(&path);
        }
    }
    let _ = std::fs::remove_dir(dir);
}

/// 清理目标目录下的当前临时区与 legacy 临时区。
pub fn cleanup_stale(target_dir: &Path, active: &HashSet<PathBuf>) {
    cleanup_dir(&target_dir.join(TEMP_DIR_NAME), active);
    cleanup_legacy(target_dir, active);
}

/// 只清理 legacy 临时区。
pub fn cleanup_legacy(target_dir: &Path, active: &HashSet<PathBuf>) {
    for name in LEGACY_TEMP_DIR_NAMES {
        cleanup_dir(&target_dir.join(name), active);
    }
}

/// 目标目录下的当前临时区为空时删除。
pub fn remove_temp_dir_if_empty(target_dir: &Path) {
    let _ = std::fs::remove_dir(target_dir.join(TEMP_DIR_NAME));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "handysend-temp-workspace-{name}-{}",
            std::process::id()
        ))
    }

    #[test]
    fn temp_path_stays_in_reserved_dir() {
        let final_path = Path::new("/dl/dir/a.txt");
        assert_eq!(
            temp_dir_for(final_path),
            PathBuf::from("/dl/dir").join(TEMP_DIR_NAME)
        );
        assert_eq!(
            temp_path_for(final_path),
            PathBuf::from("/dl/dir").join(TEMP_DIR_NAME).join("a.txt")
        );
        assert_eq!(temp_path("/dl/dir/a.txt"), temp_path_for(final_path));
    }

    #[test]
    fn cleanup_only_removes_stale_files() {
        let root = temp_root("clean");
        let _ = std::fs::remove_dir_all(&root);
        let temp = root.join(TEMP_DIR_NAME);
        std::fs::create_dir_all(&temp).unwrap();
        let stale = temp.join("stale.txt");
        let active = temp.join("active.txt");
        let user = root.join("user.txt");
        std::fs::write(&stale, b"stale").unwrap();
        std::fs::write(&active, b"active").unwrap();
        std::fs::write(&user, b"user").unwrap();

        let mut active_set = HashSet::new();
        active_set.insert(active.clone());
        cleanup_stale(&root, &active_set);

        assert!(!stale.exists(), "未完成残留应被删除");
        assert!(active.exists(), "活跃临时文件不能删");
        assert!(user.exists(), "用户文件不能删");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn cleanup_legacy_dir_removes_old_name() {
        let root = temp_root("legacy");
        let _ = std::fs::remove_dir_all(&root);
        let legacy = root.join(LEGACY_TEMP_DIR_NAMES[0]);
        std::fs::create_dir_all(&legacy).unwrap();
        std::fs::write(legacy.join("orphan.txt"), b"old").unwrap();

        cleanup_legacy(&root, &HashSet::new());

        assert!(!legacy.exists(), "旧临时目录应被清理");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn commit_moves_temp_to_final() {
        let root = temp_root("commit");
        let _ = std::fs::remove_dir_all(&root);
        let final_path = root.join("a.txt");
        let temp_path = temp_path_for(&final_path);
        std::fs::create_dir_all(temp_path.parent().unwrap()).unwrap();
        std::fs::write(&temp_path, b"payload").unwrap();

        commit(&temp_path, &final_path).unwrap();

        assert!(!temp_path.exists());
        assert_eq!(std::fs::read(&final_path).unwrap(), b"payload");
        let _ = std::fs::remove_dir_all(&root);
    }
}
