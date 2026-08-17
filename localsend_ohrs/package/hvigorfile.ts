import { harTasks } from '@ohos/hvigor-ohos-plugin';
import { execSync } from 'child_process';
import * as path from 'path';
import * as fs from 'fs';

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
 * Check if all .so outputs already exist and are newer than Rust source.
 * Returns true if we can skip the Rust build.
 */
function isRustBuildUpToDate(localsendOhrsDir: string, packageDir: string, archs: string[]): boolean {
  const libsDir = path.join(packageDir, 'libs');
  const archLibDirs = archs.map(arch => ({ arch, libDir: ARCH_LIB_DIR[arch] }));
  
  // Check that all .so files exist
  for (const { libDir } of archLibDirs) {
    const soPath = path.join(libsDir, libDir, 'liblocalsend_core.so');
    if (!fs.existsSync(soPath)) return false;
  }
  
  // Check that index.d.ts exists
  const typesIndex = path.join(packageDir, 'src', 'main', 'cpp', 'types', 'liblocalsend_core', 'index.d.ts');
  if (!fs.existsSync(typesIndex)) return false;
  
  // Compare .so mtime vs Rust source mtime
  let oldestSoMtime = Infinity;
  for (const { libDir } of archLibDirs) {
    const soPath = path.join(libsDir, libDir, 'liblocalsend_core.so');
    const soMtime = fs.statSync(soPath).mtimeMs;
    if (soMtime < oldestSoMtime) oldestSoMtime = soMtime;
  }
  const typesMtime = fs.statSync(typesIndex).mtimeMs;
  const oldestOutputMtime = Math.min(oldestSoMtime, typesMtime);
  
  // Check Rust source directories
  const rustSrcDir = path.join(localsendOhrsDir, 'rust');
  const cargoToml = path.join(localsendOhrsDir, 'Cargo.toml');
  const thirdPartyDir = path.join(localsendOhrsDir, 'third_party', 'localsend', 'packages', 'core', 'src');
  
  const rustSrcMtime = getLatestMtime(rustSrcDir);
  const cargoTomlMtime = fs.existsSync(cargoToml) ? fs.statSync(cargoToml).mtimeMs : 0;
  const thirdPartyMtime = getLatestMtime(thirdPartyDir);
  const latestSourceMtime = Math.max(rustSrcMtime, cargoTomlMtime, thirdPartyMtime);
  
  if (oldestOutputMtime > latestSourceMtime) {
    console.log(`[Incremental] .so outputs are up-to-date (output: ${new Date(oldestOutputMtime).toISOString()}, source: ${new Date(latestSourceMtime).toISOString()})`);
    return true;
  }
  
  return false;
}

/**
 * Custom plugin to build Rust NAPI before HAR packaging.
 * 
 * - Syncs version from Cargo.toml to all dependent files
 * - Incremental: skips Rust compilation if .so outputs already exist
 *   and are newer than Rust source files
 */
export function rustBuildPlugin() {
  return {
    pluginId: 'RustBuildPlugin',
    apply(pluginContext: any) {
      pluginContext.registerTask({
        name: 'BuildRustNapi',
        run: (taskContext: any) => {
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
          
          for (const arch of archs) {
            console.log(`[${moduleName}] Building for ${arch}...`);
            
            try {
              // Run ohrs build
              execSync(`ohrs build --release -a ${arch}`, {
                cwd: localsendOhrsDir,
                stdio: 'inherit',
                timeout: 600000, // 10 minutes
                env: {
                  ...process.env,
                  OHOS_NDK_HOME: ohosNdkHome
                }
              });
              
              // Copy .so to libs/
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
              
            } catch (error: any) {
              console.error(`[${moduleName}] Build failed for ${arch}:`, error.message);
              throw error;
            }
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

export default {
  system: harTasks,  /* Built-in plugin */
  plugins: [rustBuildPlugin()]  /* Custom plugin for Rust build */
}
