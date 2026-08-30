import { harTasks } from '@ohos/hvigor-ohos-plugin';
import { spawn } from 'child_process';
import * as path from 'path';
import * as fs from 'fs';
import * as crypto from 'crypto';

/**
 * Load environment variables from .env file
 */
function loadEnvFile(envPath: string): void {
  if (fs.existsSync(envPath)) {
    const content = fs.readFileSync(envPath, 'utf-8');
    const lines = content.split('\n');
    const parsed: Record<string, string> = {};
    
    for (const line of lines) {
      const trimmed = line.trim();
      // Skip empty lines and comments
      if (!trimmed || trimmed.startsWith('#')) continue;
      
      const eqIndex = trimmed.indexOf('=');
      if (eqIndex > 0) {
        const key = trimmed.substring(0, eqIndex).trim();
        let value = trimmed.substring(eqIndex + 1).trim();
        // Strip surrounding single quotes
        if (value.startsWith("'") && value.endsWith("'") && value.length >= 2) {
          value = value.substring(1, value.length - 1);
        }
        // Expand $VAR and ${VAR} references using already-parsed variables
        value = value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, varName) => {
          return parsed[varName] !== undefined ? parsed[varName] : `\${${varName}}`;
        });
        value = value.replace(/\$([A-Za-z_][A-Za-z0-9_]*)/g, (_, varName) => {
          return parsed[varName] !== undefined ? parsed[varName] : `$${varName}`;
        });
        parsed[key] = value;
        // Set to process.env if not already set
        if (!process.env[key]) {
          process.env[key] = value;
        }
      }
    }
  }
}

/**
 * Read version from Cargo.toml (single source of truth).
 */
function getCargoVersion(localsendOhrsDir: string): string {
  const cargoTomlPath = path.join(localsendOhrsDir, 'Cargo.toml');
  const cargoContent = fs.readFileSync(cargoTomlPath, 'utf-8');
  const match = cargoContent.match(/^version\s*=\s*"([^"]+)"/m);
  if (!match) {
    throw new Error('Could not read version from Cargo.toml');
  }
  return match[1];
}

/**
 * Sync version from Cargo.toml to all dependent files.
 * 
 * Cargo.toml is the single source of truth. This function reads
 * the version from Cargo.toml and writes it to:
 *   - oh-package.json5 (HAR)
 *   - oh-package.json5 (types)
 *   - NativeBridge.ets (EXPECTED_NATIVE_VERSION)
 */
function syncVersionFromCargo(localsendOhrsDir: string, packageDir: string, projectRoot: string): void {
  const version = getCargoVersion(localsendOhrsDir);
  
  // 1. Sync oh-package.json5 (HAR)
  const harOhPackagePath = path.join(packageDir, 'oh-package.json5');
  if (fs.existsSync(harOhPackagePath)) {
    let content = fs.readFileSync(harOhPackagePath, 'utf-8');
    const updated = content.replace(/"version"\s*:\s*"[^"]+"/, `"version": "${version}"`);
    if (content !== updated) {
      fs.writeFileSync(harOhPackagePath, updated, 'utf-8');
      console.log(`[VersionSync] oh-package.json5 → ${version}`);
    }
  }
  
  // 2. Sync oh-package.json5 (types)
  const typesOhPackagePath = path.join(packageDir, 'src', 'main', 'cpp', 'types', 'liblocalsend_core', 'oh-package.json5');
  if (fs.existsSync(typesOhPackagePath)) {
    let content = fs.readFileSync(typesOhPackagePath, 'utf-8');
    const updated = content.replace(/"version"\s*:\s*"[^"]+"/, `"version": "${version}"`);
    if (content !== updated) {
      fs.writeFileSync(typesOhPackagePath, updated, 'utf-8');
      console.log(`[VersionSync] types/oh-package.json5 → ${version}`);
    }
  }
  
  // 3. Sync NativeBridge.ets
  const nativeBridgePath = path.join(projectRoot, 'entry', 'src', 'main', 'ets', 'service', 'NativeBridge.ets');
  if (fs.existsSync(nativeBridgePath)) {
    let content = fs.readFileSync(nativeBridgePath, 'utf-8');
    const updated = content.replace(
      /EXPECTED_NATIVE_VERSION\s*=\s*'[^']+'/,
      `EXPECTED_NATIVE_VERSION = '${version}'`
    );
    if (content !== updated) {
      fs.writeFileSync(nativeBridgePath, updated, 'utf-8');
      console.log(`[VersionSync] NativeBridge.ets → ${version}`);
    }
  }
  
  console.log(`[VersionSync] All versions synced to ${version} (source: Cargo.toml)`);
}

/**
 * Recursively find the most recent modification time in a directory.
 * Returns 0 if directory does not exist.
 */
function getLatestMtime(dir: string): number {
  if (!fs.existsSync(dir)) return 0;
  let latest = 0;
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      const subMtime = getLatestMtime(fullPath);
      if (subMtime > latest) latest = subMtime;
    } else {
      const stat = fs.statSync(fullPath);
      if (stat.mtimeMs > latest) latest = stat.mtimeMs;
    }
  }
  return latest;
}

/**
 * ohrs --arch value → libs/ subdirectory name.
 * ohrs uses "arm64", HarmonyOS libs/ uses "arm64-v8a" as the ABI directory.
 */
const ARCH_LIB_DIR: Record<string, string> = {
  x86_64: 'x86_64',
  arm64: 'arm64-v8a',
};

/**
 * 计算文件的排序后内容哈希。
 * 
 * 将文件内容按行拆分，过滤空行和纯注释行（// 开头但非 JSDoc），
 * 按字典序排序后拼接，计算 SHA-256 哈希。
 * 排序可消除 ohrs 生成时导出顺序不确定的影响，避免误报。
 * 
 * @param filePath - 要计算哈希的文件绝对路径
 * @returns 64 字符的十六进制 SHA-256 哈希字符串
 */
const computeSortedHash = (filePath: string): string => {
  const content = fs.readFileSync(filePath, 'utf-8');
  const lines = content.split('\n');
  // 过滤空行和纯注释行（// 开头但非 JSDoc /** 或 /* 的行）
  const filtered = lines.filter(line => {
    const trimmed = line.trim();
    if (trimmed === '') return false;
    if (trimmed.startsWith('//')) return false;
    return true;
  });
  filtered.sort();
  const sorted = filtered.join('\n');
  return crypto.createHash('sha256').update(sorted, 'utf-8').digest('hex');
};

/**
 * 保存 index.d.ts 的排序后哈希到 dist 目录下的 .d.ts.hash 文件。
 * 哈希文件放在 dist/ 而非 index.d.ts 同目录，避免被打包进 HAR。
 * 
 * @param dtsPath - index.d.ts 的绝对路径
 * @param distDir - ohrs 输出目录（dist/）的绝对路径
 */
const saveDtsHash = (dtsPath: string, distDir: string): void => {
  const hash = computeSortedHash(dtsPath);
  const hashPath = path.join(distDir, '.d.ts.hash');
  fs.writeFileSync(hashPath, hash, 'utf-8');
};

/**
 * 检查 index.d.ts 是否存在且排序后哈希与 dist 目录下的 .d.ts.hash 一致。
 * 
 * @param dtsPath - index.d.ts 的绝对路径
 * @param distDir - ohrs 输出目录（dist/）的绝对路径
 * @returns true 表示文件存在且哈希一致；false 表示文件不存在或哈希不一致
 */
const isDtsConsistent = (dtsPath: string, distDir: string): boolean => {
  if (!fs.existsSync(dtsPath)) return false;
  const hashPath = path.join(distDir, '.d.ts.hash');
  if (!fs.existsSync(hashPath)) return false;
  const storedHash = fs.readFileSync(hashPath, 'utf-8').trim();
  const currentHash = computeSortedHash(dtsPath);
  return storedHash === currentHash;
};

/**
 * Resolve build architectures from OHRS_BUILD_ARCHS env var.
 * Default: arm64 (real devices only; add x86_64 for emulator).
 */
function getBuildArchs(): string[] {
  const envVal = process.env.OHRS_BUILD_ARCHS;
  if (envVal) {
    const archs = envVal.split(',').map(s => s.trim()).filter(Boolean);
    for (const arch of archs) {
      if (!ARCH_LIB_DIR[arch]) {
        throw new Error(`Unknown arch "${arch}" in OHRS_BUILD_ARCHS. Supported: ${Object.keys(ARCH_LIB_DIR).join(', ')}`);
      }
    }
    return archs;
  }
  return ['arm64'];
}

/**
 * Check if all .so outputs already exist and are newer than Rust source,
 * and index.d.ts is consistent with the stored hash.
 * Returns true if we can skip the Rust build.
 */
function isRustBuildUpToDate(localsendOhrsDir: string, packageDir: string, archs: string[]): boolean {
  const libsDir = path.join(packageDir, 'libs');
  const distDir = path.join(localsendOhrsDir, 'dist');
  const archLibDirs = archs.map(arch => ({ arch, libDir: ARCH_LIB_DIR[arch] }));
  
  // Check that all .so files exist
  for (const { libDir } of archLibDirs) {
    const soPath = path.join(libsDir, libDir, 'liblocalsend_core.so');
    if (!fs.existsSync(soPath)) return false;
  }
  
  // Compare .so mtime vs Rust source mtime
  let oldestSoMtime = Infinity;
  for (const { libDir } of archLibDirs) {
    const soPath = path.join(libsDir, libDir, 'liblocalsend_core.so');
    const soMtime = fs.statSync(soPath).mtimeMs;
    if (soMtime < oldestSoMtime) oldestSoMtime = soMtime;
  }
  
  // Check Rust source directories
  const rustSrcDir = path.join(localsendOhrsDir, 'rust');
  const cargoToml = path.join(localsendOhrsDir, 'Cargo.toml');
  const thirdPartyDir = path.join(localsendOhrsDir, 'third_party', 'localsend', 'packages', 'core', 'src');
  
  const rustSrcMtime = getLatestMtime(rustSrcDir);
  const cargoTomlMtime = fs.existsSync(cargoToml) ? fs.statSync(cargoToml).mtimeMs : 0;
  const thirdPartyMtime = getLatestMtime(thirdPartyDir);
  const latestSourceMtime = Math.max(rustSrcMtime, cargoTomlMtime, thirdPartyMtime);
  
  if (oldestSoMtime <= latestSourceMtime) {
    return false;
  }
  
  // .so 时间戳检查通过后，额外校验 index.d.ts 一致性
  const dtsPath = path.join(packageDir, 'src', 'main', 'cpp', 'types', 'liblocalsend_core', 'index.d.ts');
  if (!isDtsConsistent(dtsPath, distDir)) {
    console.log(`[DtsGuard] index.d.ts missing or hash mismatch, forcing rebuild`);
    return false;
  }
  
  console.log(`[Incremental] .so outputs are up-to-date (output: ${new Date(oldestSoMtime).toISOString()}, source: ${new Date(latestSourceMtime).toISOString()})`);
  return true;
}

/**
 * Custom plugin to build Rust NAPI before HAR packaging.
 * 
 * - Syncs version from Cargo.toml to all dependent files
 * - Incremental: skips Rust compilation if .so outputs already exist
 *   and are newer than Rust source files, and index.d.ts is consistent
 *   with the stored hash (see isRustBuildUpToDate)
 * - On build success, saves index.d.ts sorted hash to .d.ts.hash for
 *   future incremental consistency checks
 */
export function rustBuildPlugin() {
  return {
    pluginId: 'RustBuildPlugin',
    apply(pluginContext: any) {
      pluginContext.registerTask({
        name: 'BuildRustNapi',
        description: '构建 Rust NAPI 原生库（.so + index.d.ts）',
        run: async (taskContext: any) => {
          const modulePath = taskContext.modulePath;
          const moduleName = taskContext.moduleName;
          
          // Determine paths
          const packageDir = modulePath;
          const localsendOhrsDir = path.dirname(packageDir);
          const projectRoot = path.dirname(localsendOhrsDir);
          const distDir = path.join(localsendOhrsDir, 'dist');
          const libsDir = path.join(packageDir, 'libs');
          
          // Load .env file from project root
          const envFile = path.join(projectRoot, '.env');
          loadEnvFile(envFile);
          
          // Sync version from Cargo.toml (single source of truth)
          syncVersionFromCargo(localsendOhrsDir, packageDir, projectRoot);
          
          // Resolve build architectures early (needed for incremental check)
          const archs = getBuildArchs();
          
          // Incremental check: skip if .so outputs are up-to-date
          if (isRustBuildUpToDate(localsendOhrsDir, packageDir, archs)) {
            console.log('');
            console.log(`[${moduleName}] Rust NAPI is up-to-date, skipping build.`);
            console.log(`[${moduleName}] To force rebuild: delete libs/ or run clean.`);
            return;
          }
          
          console.log('');
          console.log('========================================');
          console.log(`[${moduleName}] Building Rust NAPI...`);
          console.log('========================================');
          
          // Check OHOS_NDK_HOME
          const ohosNdkHome = process.env.OHOS_NDK_HOME;
          if (!ohosNdkHome) {
            console.error(`[${moduleName}] ERROR: OHOS_NDK_HOME not set`);
            console.error(`[${moduleName}] Please create .env file in project root with:`);
            console.error(`[${moduleName}]   OHOS_NDK_HOME=<your_sdk_path>/openharmony`);
            throw new Error('OHOS_NDK_HOME not set');
          }
          
          // Ensure ~/.cargo/bin is in PATH (DevEco Studio may not inherit shell PATH)
          const homeDir = process.env.HOME || process.env.USERPROFILE || '';
          const cargoBin = process.env.CARGO_HOME
            ? path.join(process.env.CARGO_HOME, 'bin')
            : path.join(homeDir, '.cargo', 'bin');
          const currentPath = process.env.PATH || '';
          if (!currentPath.split(path.delimiter).includes(cargoBin)) {
            process.env.PATH = cargoBin + path.delimiter + currentPath;
          }
          
          console.log(`[${moduleName}] OHOS_NDK_HOME: ${ohosNdkHome}`);
          console.log(`[${moduleName}] Working directory: ${localsendOhrsDir}`);
          console.log(`[${moduleName}] Build architectures: ${archs.join(', ')}`);

          // 单次 ohrs build 传入所有架构，避免多进程争抢 cargo 全局锁导致实际串行
          const archArgs: string[] = [];
          for (const arch of archs) {
            archArgs.push('-a', arch);
          }

          try {
            await new Promise<void>((resolve, reject) => {
              const child = spawn('ohrs', ['build', '--release', ...archArgs], {
                cwd: localsendOhrsDir,
                stdio: 'inherit',
                env: {
                  ...process.env,
                  OHOS_NDK_HOME: ohosNdkHome
                }
              });
              const timeout = setTimeout(() => {
                child.kill();
                reject(new Error(`Rust build timed out (15 min)`));
              }, 900000);
              child.on('close', (code: number) => {
                clearTimeout(timeout);
                if (code === 0) {
                  console.log(`[${moduleName}] Rust build succeeded.`);
                  resolve();
                } else {
                  reject(new Error(`Rust build failed with exit code ${code}`));
                }
              });
              child.on('error', (err: Error) => {
                clearTimeout(timeout);
                reject(err);
              });
            });
          } catch (error: any) {
            console.error(`[${moduleName}] Build failed:`, error.message);
            throw error;
          }

          // Copy .so files to libs/ for each architecture
          for (const arch of archs) {
            const libArch = arch === 'arm64' ? 'arm64-v8a' : arch;
            let srcSoDir = path.join(distDir, libArch);
            
            // ohrs might output to aarch64 for arm64
            if (!fs.existsSync(srcSoDir) && arch === 'arm64') {
              srcSoDir = path.join(distDir, 'aarch64');
            }
            
            const srcSo = path.join(srcSoDir, 'liblocalsend_core.so');
            const dstSoDir = path.join(libsDir, libArch);
            const dstSo = path.join(dstSoDir, 'liblocalsend_core.so');
            
            if (!fs.existsSync(srcSo)) {
              throw new Error(`Built .so not found: ${srcSo}`);
            }
            
            // Ensure destination directory exists
            if (!fs.existsSync(dstSoDir)) {
              fs.mkdirSync(dstSoDir, { recursive: true });
            }
            
            // Copy .so
            fs.copyFileSync(srcSo, dstSo);
            console.log(`[${moduleName}] Copied .so to libs/${libArch}/`);
          }
          
          // Copy index.d.ts to cpp/types/ (for DevEco type resolution)
          const srcIndex = path.join(distDir, 'index.d.ts');
          const typesDir = path.join(packageDir, 'src', 'main', 'cpp', 'types', 'liblocalsend_core');
          const dstTypesIndex = path.join(typesDir, 'index.d.ts');  // lowercase for DevEco
          
          if (fs.existsSync(srcIndex)) {
            if (!fs.existsSync(typesDir)) {
              fs.mkdirSync(typesDir, { recursive: true });
            }
            fs.copyFileSync(srcIndex, dstTypesIndex);
            console.log(`[${moduleName}] Copied index.d.ts to cpp/types/`);
            // 保存 index.d.ts 的排序后哈希基准到 dist/，用于后续增量构建一致性检查
            saveDtsHash(dstTypesIndex, distDir);
            console.log(`[DtsGuard] Saved .d.ts.hash`);
          } else {
            throw new Error(`index.d.ts not found: ${srcIndex}`);
          }
          
          console.log('');
          console.log(`[${moduleName}] Rust NAPI build complete!`);
          console.log('========================================');
        },
        // Run after PreBuild, before BuildNativeWithCmake
        dependencies: ['default@PreBuild'],
        postDependencies: ['default@BuildNativeWithCmake']
      });
    }
  };
}

/**
 * Custom plugin to run Rust tests from DevEco Studio.
 *
 * 注册三个 hvigor task，对应 BUILD.md 中的三种 Rust 测试：
 *   - RustTestUnit：      桥接层单元测试（--no-default-features --lib）
 *   - RustTestIntegration：桥接层集成测试（localsend_ohrs/tests/ 独立 crate）
 *   - RustTestUpstream：   上游 localsend crate 测试
 *
 * 在 DevEco Studio 侧边 hvigor 工具面板中执行，或命令行：hvigorw RustTestUnit -p module=localsend_ohrs
 */
export function rustTestPlugin() {
  return {
    pluginId: 'RustTestPlugin',
    apply(pluginContext: any) {
      // 桥接层单元测试
      pluginContext.registerTask({
        name: 'RustTestUnit',
        description: '桥接层单元测试（--no-default-features --lib）',
        run: async (taskContext: any) => {
          const localsendOhrsDir = path.dirname(taskContext.modulePath);
          loadEnvFile(path.join(path.dirname(localsendOhrsDir), '.env'));
          ensureCargoInPath();
          await runCargo(
            localsendOhrsDir,
            ['test', '--target', 'x86_64-unknown-linux-gnu', '--no-default-features', '--lib'],
            '桥接层单元测试'
          );
        },
        dependencies: [],
        postDependencies: []
      });

      // 桥接层集成测试
      pluginContext.registerTask({
        name: 'RustTestIntegration',
        description: '桥接层集成测试（localsend_ohrs/tests/ 独立 crate）',
        run: async (taskContext: any) => {
          const localsendOhrsDir = path.dirname(taskContext.modulePath);
          loadEnvFile(path.join(path.dirname(localsendOhrsDir), '.env'));
          ensureCargoInPath();
          await runCargo(
            path.join(localsendOhrsDir, 'tests'),
            ['test', '--target', 'x86_64-unknown-linux-gnu'],
            '桥接层集成测试'
          );
        },
        dependencies: [],
        postDependencies: []
      });

      // 上游 localsend crate 测试
      pluginContext.registerTask({
        name: 'RustTestUpstream',
        description: '上游 localsend crate 测试（crypto,discovery,http,multicast）',
        run: async (taskContext: any) => {
          const localsendOhrsDir = path.dirname(taskContext.modulePath);
          loadEnvFile(path.join(path.dirname(localsendOhrsDir), '.env'));
          ensureCargoInPath();
          await runCargo(
            path.join(localsendOhrsDir, 'third_party', 'localsend'),
            ['test', '--target', 'x86_64-unknown-linux-gnu', '-p', 'localsend', '--features', 'crypto,discovery,http,multicast'],
            '上游 localsend crate 测试'
          );
        },
        dependencies: [],
        postDependencies: []
      });
    }
  };
}

/**
 * 确保 ~/.cargo/bin 在 PATH 中（DevEco Studio 可能不继承 shell PATH）
 */
function ensureCargoInPath(): void {
  const homeDir = process.env.HOME || process.env.USERPROFILE || '';
  const cargoBin = process.env.CARGO_HOME
    ? path.join(process.env.CARGO_HOME, 'bin')
    : path.join(homeDir, '.cargo', 'bin');
  const currentPath = process.env.PATH || '';
  if (!currentPath.split(path.delimiter).includes(cargoBin)) {
    process.env.PATH = cargoBin + path.delimiter + currentPath;
  }
}

/**
 * 执行 cargo 命令并等待完成
 */
async function runCargo(cwd: string, args: string[], label: string): Promise<void> {
  console.log('');
  console.log('========================================');
  console.log(`[RustTest] ${label}`);
  console.log(`[RustTest] 工作目录: ${cwd}`);
  console.log(`[RustTest] 命令: cargo ${args.join(' ')}`);
  console.log('========================================');

  await new Promise<void>((resolve, reject) => {
    const child = spawn('cargo', args, {
      cwd: cwd,
      stdio: 'inherit',
    });
    const timeout = setTimeout(() => {
      child.kill();
      reject(new Error(`${label}超时 (10 min)`));
    }, 600000);
    child.on('close', (code: number) => {
      clearTimeout(timeout);
      if (code === 0) {
        console.log(`[RustTest] ${label} 通过`);
        resolve();
      } else {
        reject(new Error(`${label}失败，退出码 ${code}`));
      }
    });
    child.on('error', (err: Error) => {
      clearTimeout(timeout);
      reject(err);
    });
  });
}

export default {
  system: harTasks,  /* Built-in plugin */
  plugins: [rustBuildPlugin(), rustTestPlugin()]  /* Custom plugins for Rust build & test */
}
