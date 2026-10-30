-- Automatic installer for libvscode-diff binary
-- Downloads pre-built binaries from GitHub releases

local M = {}

local common = require("codediff.core.installer.common")

-- Status messages respect silent mode; failures still report their cause.
local function notify(opts, message, level)
  if not opts.silent then
    vim.notify(message, level)
  end
end

local function fail(message, temp_path)
  vim.notify(message, vim.log.levels.ERROR)
  if temp_path then
    os.remove(temp_path)
  end
  return false, message
end

-- Get the plugin root directory using shared path utility
local path_util = require("codediff.core.path")
local function get_plugin_root()
  return path_util.get_plugin_root()
end

-- Get library extension for current OS
local function get_lib_ext()
  local ffi = require("ffi")
  if ffi.os == "Windows" then
    return "dll"
  elseif ffi.os == "OSX" then
    return "dylib"
  else
    return "so"
  end
end

-- Get library filename with version
local function get_lib_filename(version)
  return string.format("libvscode_diff_%s.%s", version, get_lib_ext())
end

-- Get unversioned library filename (for manual builds)
local function get_unversioned_lib_filename()
  return "libvscode_diff." .. get_lib_ext()
end

-- Get the current VERSION from version.lua (single source of truth)
local function get_current_version()
  local version = require("codediff.version")
  return version.VERSION
end

-- Get installed library version by checking existing versioned files
-- Returns the latest version if multiple libraries exist
local function get_installed_version()
  local plugin_root = get_plugin_root()
  local ext = get_lib_ext()
  -- Escape the dot in the extension for pattern matching
  local pattern = "libvscode_diff_(.+)%." .. ext

  local versions = {}

  -- List files in plugin root and find all versioned libraries
  local handle = vim.loop.fs_scandir(plugin_root)
  if handle then
    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end

      -- type can be nil on network filesystems (e.g. NFS) where d_type
      -- is not populated, so only exclude known non-file types
      if type ~= "directory" and type ~= "link" then
        local version = name:match(pattern)
        if version then
          table.insert(versions, version)
        end
      end
    end
  end

  if #versions > 0 then
    table.sort(versions, function(a, b)
      -- Parse semantic versions (e.g., "0.11.1")
      local a_parts = vim.split(a, "%.")
      local b_parts = vim.split(b, "%.")

      for i = 1, math.max(#a_parts, #b_parts) do
        local a_num = tonumber(a_parts[i]) or 0
        local b_num = tonumber(b_parts[i]) or 0
        if a_num ~= b_num then
          return a_num > b_num
        end
      end
      return false
    end)
    return versions[1]
  end

  return nil
end

-- Build download URL for GitHub release
local function build_download_url(os, arch, version)
  if not version or version == "" then
    return nil, nil, "VERSION is not available"
  end

  local ext = get_lib_ext()
  -- Download filename from GitHub (includes platform info)
  local download_filename = string.format("libvscode_diff_%s_%s_%s.%s", os, arch, version, ext)
  -- Local filename (only includes version)
  local local_filename = get_lib_filename(version)

  local url = string.format("https://github.com/esmuellert/codediff.nvim/releases/download/v%s/%s", version, download_filename)

  return url, local_filename, nil
end

-- Nix's linker does not use the system ldconfig cache; bundle libgomp beside the .so.
local function is_nvim_from_nix()
  local resolved = vim.fn.resolve(vim.v.progpath)
  return resolved:find("^/nix/store") ~= nil
end

-- Use ldconfig rather than ffi.load: LD_LIBRARY_PATH can hide a missing dependency.
local function check_system_libgomp()
  local os_name = common.detect_os()

  -- Only check on Linux (macOS and Windows don't use libgomp)
  if os_name ~= "linux" then
    return true
  end

  -- Check if already bundled in plugin directory (RPATH $ORIGIN)
  local plugin_root = get_plugin_root()
  if vim.fn.filereadable(plugin_root .. "/libgomp.so.1") == 1 then
    return true
  end

  if is_nvim_from_nix() then
    return false
  end

  -- Check ldconfig cache - this is what the native linker actually uses
  -- (excluding unreliable LD_LIBRARY_PATH which varies per session)
  local handle = io.popen("ldconfig -p 2>/dev/null | grep -q 'libgomp\\.so\\.1' && echo 'found'")
  if handle then
    local result = handle:read("*a")
    handle:close()
    if result:match("found") then
      return true
    end
  end

  -- Not found in ldconfig cache or ldconfig unavailable → bundle to be safe
  return false
end

-- Install libgomp if needed
local function install_libgomp_if_needed(opts)
  local os_name = common.detect_os()

  -- Only needed on Linux
  if os_name ~= "linux" then
    return true
  end

  local plugin_root = get_plugin_root()
  local libgomp_path = plugin_root .. "/libgomp.so.1"

  if vim.fn.filereadable(libgomp_path) == 1 then
    notify(opts, "libgomp.so.1 already bundled", vim.log.levels.DEBUG)
    return true
  end

  if check_system_libgomp() then
    notify(opts, "System libgomp.so.1 found, no need to bundle", vim.log.levels.DEBUG)
    return true
  end

  notify(opts, "System libgomp.so.1 not found, downloading...", vim.log.levels.INFO)

  local arch, arch_err = common.detect_arch()
  if not arch then
    return fail("Failed to detect architecture: " .. (arch_err or "unknown error"))
  end

  local current_version = get_current_version()
  if not current_version then
    return fail("Failed to read VERSION")
  end

  local libgomp_filename = string.format("libgomp_linux_%s_%s.so.1", arch, current_version)
  local url = string.format("https://github.com/esmuellert/codediff.nvim/releases/download/v%s/%s", current_version, libgomp_filename)

  notify(opts, "Downloading libgomp from: " .. url, vim.log.levels.INFO)

  local temp_path = plugin_root .. "/libgomp.so.1.tmp"
  local success, err = common.download_file(url, temp_path)

  if not success then
    local msg = "Failed to download libgomp: " .. (err or "unknown error")
    vim.notify(msg, vim.log.levels.WARN)
    vim.notify("Plugin may not work without libgomp installed on your system", vim.log.levels.WARN)
    os.remove(temp_path)
    -- Don't fail the installation, just warn
    return true
  end

  if vim.fn.filereadable(libgomp_path) == 1 then
    os.remove(libgomp_path)
  end

  local ok = os.rename(temp_path, libgomp_path)
  if not ok then
    local msg = "Failed to move libgomp to final location"
    vim.notify(msg, vim.log.levels.WARN)
    os.remove(temp_path)
    return true -- Don't fail installation
  end

  notify(opts, "Successfully downloaded libgomp.so.1", vim.log.levels.INFO)

  return true
end

-- Install the library
function M.install(opts)
  opts = opts or {}
  local force = opts.force or false

  local plugin_root = get_plugin_root()
  local current_version = get_current_version()

  if not current_version then
    return fail("Failed to read VERSION")
  end

  local lib_filename = get_lib_filename(current_version)
  local lib_path = plugin_root .. "/" .. lib_filename

  -- Check if library already exists and is up-to-date
  if not force then
    -- Check for unversioned library (manual build) first
    local unversioned_lib = get_unversioned_lib_filename()
    local unversioned_path = plugin_root .. "/" .. unversioned_lib
    if vim.fn.filereadable(unversioned_path) == 1 then
      notify(opts, "libvscode-diff (manual build) found at: " .. unversioned_path, vim.log.levels.INFO)
      -- Still check and install libgomp if needed (e.g., Nix environment)
      install_libgomp_if_needed(opts)
      return true
    end

    local installed_version = get_installed_version()

    if installed_version and installed_version == current_version then
      if vim.fn.filereadable(lib_path) == 1 then
        notify(opts, "libvscode-diff already installed at: " .. lib_path, vim.log.levels.INFO)
        -- Still check and install libgomp if needed (e.g., Nix environment)
        install_libgomp_if_needed(opts)
        return true
      end
    elseif installed_version and not opts.silent then
      vim.notify(string.format("Updating libvscode-diff from v%s to v%s...", installed_version, current_version), vim.log.levels.INFO)

      -- Remove old version files
      local old_lib_filename = get_lib_filename(installed_version)
      local old_lib_path = plugin_root .. "/" .. old_lib_filename
      if vim.fn.filereadable(old_lib_path) == 1 then
        os.remove(old_lib_path)
      end
    end
  end

  local os_name = common.detect_os()
  local arch, arch_err = common.detect_arch()

  if not arch then
    return fail("Failed to detect architecture: " .. (arch_err or "unknown error"))
  end

  local url, local_filename, url_err = build_download_url(os_name, arch, current_version)

  if not url then
    return fail("Failed to build download URL: " .. (url_err or "unknown error"))
  end

  local temp_path = plugin_root .. "/" .. local_filename .. ".tmp"
  local success, err = common.download({
    name = "libvscode-diff",
    version = current_version,
    os = os_name,
    arch = arch,
    url = url,
    destination = temp_path,
    silent = opts.silent,
  })

  if not success then
    return fail("Failed to download library: " .. (err or "unknown error"), temp_path)
  end

  -- On Windows, os.rename fails if destination exists, so remove it first
  if vim.fn.filereadable(lib_path) == 1 then
    os.remove(lib_path)
  end

  local ok = os.rename(temp_path, lib_path)
  if not ok then
    return fail("Failed to move library to final location: " .. lib_path, temp_path)
  end

  common.notify_success("libvscode-diff", opts.silent)

  -- Also check and install libgomp if needed
  install_libgomp_if_needed(opts)

  return true
end

function M.is_installed()
  local lib_path = M.get_lib_path()
  return lib_path ~= nil and vim.fn.filereadable(lib_path) == 1
end

-- Get library path
function M.get_lib_path()
  local plugin_root = get_plugin_root()

  -- Check unversioned first (manual build)
  local unversioned_lib = get_unversioned_lib_filename()
  local unversioned_path = plugin_root .. "/" .. unversioned_lib
  if vim.fn.filereadable(unversioned_path) == 1 then
    return unversioned_path
  end

  local current_version = get_current_version()
  if not current_version then
    return nil
  end

  return plugin_root .. "/" .. get_lib_filename(current_version)
end

-- Get the installed library version (by checking existing versioned files)
function M.get_installed_version()
  return get_installed_version()
end

-- Check if library needs update
function M.needs_update()
  local plugin_root = get_plugin_root()

  -- Check unversioned first - assume manual build is always up to date
  local unversioned_lib = get_unversioned_lib_filename()
  if vim.fn.filereadable(plugin_root .. "/" .. unversioned_lib) == 1 then
    return false
  end

  -- Check libgomp - if missing, we need to run installer regardless of main library status
  if not check_system_libgomp() then
    return true
  end

  local current_version = get_current_version()
  if not current_version then
    return true
  end

  local installed_version = get_installed_version()

  if not installed_version then
    return true
  end

  return current_version ~= installed_version
end

return M
