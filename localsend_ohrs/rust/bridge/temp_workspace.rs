//! 接收落盘临时区——应用独占的隐藏目录 + 同文件系统原子改名。
//!
//! 未完成字节写在最终文件同父目录的 `.handysend-temp/` 中，并按协议使用独立
//! 子目录（LocalSend/MTA/网页上传）。临时文件存在即表示对应最终文件名已被
//! 占用，避免不同协议或并发会话的同名文件互相截断；完成后 `rename` 到最终路径。
//! 旧版本目录 `.handysend-upload-part/` 作为 legacy 名称 best-effort 清理。

use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// 当前临时区根目录名。
pub const TEMP_DIR_NAME: &str = ".handysend-temp";

/// 各接收协议的临时子目录名。
pub const TEMP_SUBDIR_LOCAL_SEND: &str = "local-send";
pub const TEMP_SUBDIR_MTA: &str = "mta";
pub const TEMP_SUBDIR_WEB: &str = "web";
pub const TEMP_SUBDIRS: &[&str] = &[TEMP_SUBDIR_LOCAL_SEND, TEMP_SUBDIR_MTA, TEMP_SUBDIR_WEB];

/// 旧版本临时区目录名，仅用于清理残留。
pub const LEGACY_TEMP_DIR_NAMES: &[&str] = &[".handysend-upload-part"];

/// 最终路径对应的临时区根目录。
pub fn temp_root_for(final_path: &Path) -> PathBuf {
    final_path
        .parent()
        .unwrap_or_else(|| Path::new(""))
        .join(TEMP_DIR_NAME)
}

/// 最终路径在指定协议子目录下的临时目录。
pub fn temp_dir_for(final_path: &Path, subdir: &str) -> PathBuf {
    temp_root_for(final_path).join(subdir)
}

/// 最终路径在指定协议子目录下的临时文件路径（文件名与最终文件相同）。
pub fn temp_path_for(final_path: &Path, subdir: &str) -> PathBuf {
    let name = final_path
        .file_name()
        .map(|name| name.to_os_string())
        .unwrap_or_default();
    temp_dir_for(final_path, subdir).join(name)
}

/// 字符串路径便捷入口。
pub fn temp_dir(final_path: &str, subdir: &str) -> PathBuf {
    temp_dir_for(Path::new(final_path), subdir)
}

/// 字符串路径便捷入口。
pub fn temp_path(final_path: &str, subdir: &str) -> PathBuf {
    temp_path_for(Path::new(final_path), subdir)
}

/// 目标目录中的文件名是否已被最终文件或任一协议的临时文件占用。
pub fn is_name_reserved(dir: &Path, name: &str) -> bool {
    if dir.join(name).exists() {
        return true;
    }
    for subdir in TEMP_SUBDIRS {
        if dir.join(TEMP_DIR_NAME).join(subdir).join(name).exists() {
            return true;
        }
    }
    for legacy in LEGACY_TEMP_DIR_NAMES {
        if dir.join(legacy).join(name).exists() {
            return true;
        }
    }
    false
}

/// 原子提交：把临时文件改名为最终文件（同一文件系统内）。
pub fn commit(temp: &Path, final_path: &Path) -> std::io::Result<()> {
    std::fs::rename(temp, final_path)
}

/// 删除临时文件，并尝试移除已空的协议子目录与临时区根目录。
pub fn remove_temp_file(path: &Path) {
    let _ = std::fs::remove_file(path);
    if let Some(dir) = path.parent() {
        let _ = std::fs::remove_dir(dir);
        if is_protocol_subdir(dir) {
            if let Some(root) = dir.parent() {
                let _ = std::fs::remove_dir(root);
            }
        }
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

/// 清理目标目录下指定协议子目录中的遗留文件。
pub fn cleanup_namespace(target_dir: &Path, subdir: &str, active: &HashSet<PathBuf>) {
    let dir = target_dir.join(TEMP_DIR_NAME).join(subdir);
    cleanup_dir(&dir, active);
    let _ = std::fs::remove_dir(target_dir.join(TEMP_DIR_NAME));
}

/// 只清理 legacy 临时区。
pub fn cleanup_legacy(target_dir: &Path, active: &HashSet<PathBuf>) {
    for name in LEGACY_TEMP_DIR_NAMES {
        cleanup_dir(&target_dir.join(name), active);
    }
}

/// 目标目录下指定协议的临时子目录为空时删除（并尝试移除空根目录）。
pub fn remove_temp_dir_if_empty(target_dir: &Path, subdir: &str) {
    let root = target_dir.join(TEMP_DIR_NAME);
    let _ = std::fs::remove_dir(root.join(subdir));
    let _ = std::fs::remove_dir(root);
}

fn is_protocol_subdir(dir: &Path) -> bool {
    dir.file_name()
        .and_then(|name| name.to_str())
        .map(|name| TEMP_SUBDIRS.contains(&name))
        .unwrap_or(false)
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
    fn temp_path_stays_in_reserved_subdir() {
        let final_path = Path::new("/dl/dir/a.txt");
        assert_eq!(
            temp_dir_for(final_path, TEMP_SUBDIR_LOCAL_SEND),
            PathBuf::from("/dl/dir")
                .join(TEMP_DIR_NAME)
                .join(TEMP_SUBDIR_LOCAL_SEND)
        );
        assert_eq!(
            temp_path_for(final_path, TEMP_SUBDIR_LOCAL_SEND),
            PathBuf::from("/dl/dir")
                .join(TEMP_DIR_NAME)
                .join(TEMP_SUBDIR_LOCAL_SEND)
                .join("a.txt")
        );
        assert_eq!(
            temp_path("/dl/dir/a.txt", TEMP_SUBDIR_LOCAL_SEND),
            temp_path_for(final_path, TEMP_SUBDIR_LOCAL_SEND)
        );
    }

    #[test]
    fn name_reservation_sees_other_protocol_temp() {
        let root = temp_root("reserve");
        let _ = std::fs::remove_dir_all(&root);
        let temp = root.join(TEMP_DIR_NAME).join(TEMP_SUBDIR_WEB);
        std::fs::create_dir_all(&temp).unwrap();
        std::fs::write(temp.join("photo.jpg"), b"half").unwrap();

        assert!(
            is_name_reserved(&root, "photo.jpg"),
            "其他协议临时文件应视为占用"
        );
        assert!(!is_name_reserved(&root, "other.jpg"));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn cleanup_only_removes_stale_files() {
        let root = temp_root("clean");
        let _ = std::fs::remove_dir_all(&root);
        let temp = root.join(TEMP_DIR_NAME).join(TEMP_SUBDIR_LOCAL_SEND);
        std::fs::create_dir_all(&temp).unwrap();
        let stale = temp.join("stale.txt");
        let active = temp.join("active.txt");
        let user = root.join("user.txt");
        std::fs::write(&stale, b"stale").unwrap();
        std::fs::write(&active, b"active").unwrap();
        std::fs::write(&user, b"user").unwrap();

        let mut active_set = HashSet::new();
        active_set.insert(active.clone());
        cleanup_namespace(&root, TEMP_SUBDIR_LOCAL_SEND, &active_set);

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
        let temp = temp_path_for(&final_path, TEMP_SUBDIR_LOCAL_SEND);
        std::fs::create_dir_all(temp.parent().unwrap()).unwrap();
        std::fs::write(&temp, b"payload").unwrap();

        commit(&temp, &final_path).unwrap();

        assert!(!temp.exists());
        assert_eq!(std::fs::read(&final_path).unwrap(), b"payload");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn remove_temp_file_removes_empty_subdir_and_root() {
        let root = temp_root("remove-empty");
        let _ = std::fs::remove_dir_all(&root);
        let temp = temp_path_for(&root.join("a.txt"), TEMP_SUBDIR_MTA);
        std::fs::create_dir_all(temp.parent().unwrap()).unwrap();
        std::fs::write(&temp, b"half").unwrap();

        remove_temp_file(&temp);

        assert!(!temp.exists());
        assert!(!root.join(TEMP_DIR_NAME).exists(), "空临时区根目录应被删除");
        let _ = std::fs::remove_dir_all(&root);
    }
}
