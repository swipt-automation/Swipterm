import Foundation
import SwiptermKit

nonisolated enum ContainerProvisioner {
    struct Request: Sendable {
        let hostname: String
        let user: String
        let password: String?
        let software: ContainerSoftware
    }

    static let path = "/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    static func configuration(terminal: LinuxTerminal, request: Request, release: OSRelease?) -> LinuxProcess.Configuration {
        let distribution = release?.distribution
        let software = request.software
        let developerTools = software.installedDeveloperTools
        var environment = [
            "PATH": path,
            "HOME": "/root",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LANG": "C.UTF-8",
            "DEBIAN_FRONTEND": "noninteractive",
            "SWIPTERM_DISTRIBUTION": distribution?.rawValue ?? "",
            "SWIPTERM_VERSION_ID": release?.versionID ?? "",
            "SWIPTERM_USER": request.user,
            "SWIPTERM_KERNEL_STAGING": KernelBootstrap.stagingDirectory,
            "SWIPTERM_TOOLS": DeveloperTool.allCases.filter(developerTools.contains).map(\.rawValue).joined(separator: " "),
            "SWIPTERM_AGENTS": CodingAgent.allCases.filter(software.agents.contains).map(\.rawValue).joined(separator: " "),
        ]
        for (id, title) in stepTitles {
            environment["SWIPTERM_STEP_\(id)"] = title
        }
        for (id, text) in messages {
            environment["SWIPTERM_TEXT_\(id)"] = text
        }
        if let password = request.password, !password.isEmpty {
            environment["SWIPTERM_PASSWORD"] = password
        }
        if let shell = software.shell {
            environment["SWIPTERM_SHELL"] = shell.rawValue
        }
        if let ssh = software.ssh {
            environment["SWIPTERM_SSH_PORT"] = String(ssh.port)
            environment["SWIPTERM_SSH_PASSWORD_AUTHENTICATION"] = ssh.authentication.allowsPassword ? "yes" : "no"
            environment["SWIPTERM_SSH_PUBKEY_AUTHENTICATION"] = ssh.authentication.allowsPublicKey ? "yes" : "no"
            if !ssh.authorizedKeys.isEmpty {
                environment["SWIPTERM_SSH_AUTHORIZED_KEYS"] = ssh.authorizedKeys
            }
        }

        return LinuxProcess.Configuration(
            executablePath: "/bin/sh",
            arguments: ["-c", setupScript, "swipterm-setup"],
            environment: environment,
            workingDirectory: "/",
            standardInput: .null,
            standardOutput: .terminal(terminal),
            standardError: .terminal(terminal)
        )
    }

    private static var stepTitles: KeyValuePairs<String, String> {
        [
            "kernel": String(localized: "Registering Kernel"),
            "modules": String(localized: "Indexing Modules"),
            "locale": String(localized: "Generating Locales"),
            "keyring": String(localized: "Initializing Keyring"),
            "packages": String(localized: "Installing Packages"),
            "go": String(localized: "Installing \("Go")"),
            "node": String(localized: "Installing \("Node.js")"),
            "pnpm": String(localized: "Installing \("pnpm")"),
            "bun": String(localized: "Installing \("Bun")"),
            "account": String(localized: "Configuring Account"),
            "shell": String(localized: "Configuring Shell"),
            "ssh": String(localized: "Configuring \("SSH")"),
            "docker": String(localized: "Configuring \("Docker")"),
            "rust": String(localized: "Installing \("Rust")"),
            "claude_code": String(localized: "Installing \("Claude Code")"),
            "codex": String(localized: "Installing \("Codex")"),
            "antigravity": String(localized: "Installing \("Antigravity")"),
            "cleanup": String(localized: "Cleaning Up"),
        ]
    }

    private static var messages: KeyValuePairs<String, String> {
        [
            "error": String(localized: "error:"),
            "warning": String(localized: "warning:"),
            "latest_version": String(localized: "Could not resolve the latest version of \("%s")."),
            "template_user": String(localized: "Could not remove the template user \("%s")."),
            "not_installed": String(localized: "\("%s") is not installed."),
            "system_account": String(localized: "\("%s") is a system account. Choose another username."),
            "rejected_configuration": String(localized: "\("%s") rejected the generated configuration."),
            "invalid_username": String(localized: "Invalid username: \("%s")"),
            "unrecognized_distribution": String(localized: "The distribution is not recognized; skipping the selected software."),
        ]
    }

    private static let setupScript = #"""
    set -eu
    umask 022

    user=$SWIPTERM_USER
    progress=/var/lib/swipterm/setup-progress
    [ -d /tmp ] || mkdir -m 1777 /tmp
    rm -rf /tmp/swipterm.* /tmp/swipterm-rustup.*
    work=$(mktemp -d /tmp/swipterm.XXXXXX)
    policy_rc_d=
    if grep -qsx '# swipterm' /usr/sbin/policy-rc.d; then
        policy_rc_d=/usr/sbin/policy-rc.d
    fi
    cleanup() {
        if [ -n "$policy_rc_d" ]; then
            rm -f "$policy_rc_d"
        fi
        rm -rf "$work"
    }
    trap cleanup EXIT

    step() {
        eval "title=\$SWIPTERM_STEP_$1"
        printf '\n\033[1m==> %s\033[0m\n' "$title"
    }

    stage() {
        if grep -qsx "$1" "$progress"; then
            return 0
        fi
        "$1"
        sync
        mkdir -p "${progress%/*}"
        printf '%s\n' "$1" >> "$progress"
    }

    fail() {
        eval "format=\$SWIPTERM_TEXT_$1"
        shift
        printf "\033[1;31m%s\033[0m $format\n" "$SWIPTERM_TEXT_error" "$@" >&2
        exit 1
    }

    warn() {
        eval "format=\$SWIPTERM_TEXT_$1"
        shift
        printf "\033[1;33m%s\033[0m $format\n" "$SWIPTERM_TEXT_warning" "$@" >&2
    }

    have() {
        command -v "$1" >/dev/null 2>&1
    }

    set_option() {
        mkdir -p "${1%/*}"
        if [ -f "$1" ] && grep -q "^$2=" "$1"; then
            sed -i "s/^$2=.*/$2=$3/" "$1"
        else
            printf '%s=%s\n' "$2" "$3" >> "$1"
        fi
    }

    mask() {
        for path in "$@"; do
            mkdir -p "${path%/*}"
            ln -sf /dev/null "$path"
        done
    }

    in_group() {
        id -nG "$1" | tr ' ' '\n' | grep -qx "$2"
    }

    ensure_group() {
        grep -q "^$1:" /etc/group && return 0
        if have groupadd; then
            groupadd --system "$1"
        else
            addgroup -S "$1"
        fi
    }

    join_group() {
        in_group "$user" "$1" && return 0
        if have usermod; then
            usermod -a -G "$1" "$user"
        else
            addgroup "$user" "$1"
        fi
    }

    want_tool() {
        case "$tools" in
        *" $1 "*) return 0 ;;
        esac
        return 1
    }

    want_agent() {
        case "$agents" in
        *" $1 "*) return 0 ;;
        esac
        return 1
    }

    version_at_least() {
        version=${SWIPTERM_VERSION_ID%%_*}
        version_major=${version%%.*}
        version_minor=${version#"$version_major"}
        version_minor=${version_minor#.}
        version_minor=${version_minor%%.*}
        [ "${version_major:-0}" -gt "$1" ] ||
            { [ "${version_major:-0}" -eq "$1" ] && [ "${version_minor:-0}" -ge "${2:-0}" ]; }
    }

    has_recent_packages() {
        case "$SWIPTERM_DISTRIBUTION" in
        alma | oracle | rocky) version_at_least 9 ;;
        debian) [ -z "$SWIPTERM_VERSION_ID" ] || version_at_least 14 ;;
        ubuntu) version_at_least 26 ;;
        devuan | openEuler) return 1 ;;
        *) return 0 ;;
        esac
    }

    go_from_packages() {
        if [ "$SWIPTERM_DISTRIBUTION" = alpine ]; then
            version_at_least 3 24
        else
            has_recent_packages
        fi
    }

    fetch() {
        curl -fsSL --retry 3 "$1"
    }

    download() {
        curl -fL --retry 3 --progress-bar -o "$2" "$1"
    }

    json_value() {
        grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/'
    }

    npm_tarball() {
        fetch "$npm_registry/$1/$2" > "$work/package.json"
        tarball=$(json_value tarball < "$work/package.json")
        case "$tarball" in
        /*) tarball=$npm_registry$tarball ;;
        esac
        download "$tarball" "$3"
    }

    as_user() {
        su -l -s /bin/sh "$user" -c "[ -r /etc/profile.d/swipterm.sh ] && . /etc/profile.d/swipterm.sh; $1"
    }

    generate_locale() {
        step locale
        if ! grep -q '^en_US\.UTF-8 UTF-8' /etc/locale.gen; then
            if grep -q '^#[[:space:]]*en_US\.UTF-8 UTF-8' /etc/locale.gen; then
                sed -i 's/^#[[:space:]]*\(en_US\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
            else
                printf 'en_US.UTF-8 UTF-8\n' >> /etc/locale.gen
            fi
        fi
        locale-gen
    }

    init_keyring() {
        step keyring
        pacman-key --init
        if [ -f /usr/share/pacman/keyrings/archlinuxarm.gpg ]; then
            pacman-key --populate archlinuxarm
        else
            pacman-key --populate
        fi
    }

    prepare_dnf() {
        grep -qs '^\[main\]' /etc/dnf/dnf.conf || printf '[main]\n' >> /etc/dnf/dnf.conf
        set_option /etc/dnf/dnf.conf max_parallel_downloads 5
    }

    index_modules() {
        indexed=
        for modules in /lib/modules/* /usr/lib/modules/*; do
            if [ -d "$modules" ] && [ ! -e "$modules/modules.dep.bin" ]; then
                if [ -z "$indexed" ]; then
                    step modules
                    have depmod || install_packages kmod
                    indexed=1
                fi
                depmod "${modules##*/}"
            fi
        done
    }

    reconcile_kernel() {
        staged=$SWIPTERM_KERNEL_STAGING
        if [ ! -d "$staged" ]; then
            index_modules
            return 0
        fi
        step kernel
        case "$SWIPTERM_DISTRIBUTION" in
        debian | devuan | kali | ubuntu)
            set_option /etc/initramfs-tools/update-initramfs.conf update_initramfs no
            sync_packages
            INITRD=No apt-get install -f -y --no-install-recommends -o Dpkg::Options::=--force-confold
            ;;
        alpine)
            set_option /etc/mkinitfs/mkinitfs.conf disable_trigger yes
            ;;
        arch)
            mask /etc/pacman.d/hooks/90-mkinitcpio-install.hook
            ;;
        alma | centos | fedora | openEuler | openSUSE | oracle | rocky)
            mask /etc/kernel/install.d/50-dracut.install /etc/kernel/install.d/20-grub.install
            if [ "$SWIPTERM_DISTRIBUTION" = openEuler ] && ! grep -qs '^dracut()' /etc/sysconfig/kernel; then
                mkdir -p /etc/sysconfig
                printf 'dracut() { :; }\n' >> /etc/sysconfig/kernel
            fi
            rpm -i --justdb --nodeps --noscripts --notriggers --nodigest --nosignature --replacepkgs "$staged"/*.rpm
            ;;
        esac
        index_modules
        rm -rf "$staged"
    }

    add() {
        packages="$packages $*"
    }

    downloads_upstream() {
        if want_agent codex || want_agent antigravity || want_tool rust; then
            return 0
        fi
        if want_tool go && ! go_from_packages; then
            return 0
        fi
        if want_tool node && ! has_recent_packages; then
            return 0
        fi
        [ "$SWIPTERM_DISTRIBUTION" != arch ] && { want_tool pnpm || want_tool bun; }
    }

    collect_packages() {
        packages=
        case "${SWIPTERM_SHELL:-}:$SWIPTERM_DISTRIBUTION" in
        bash:*) have bash || add bash ;;
        zsh:*) have zsh || add zsh ;;
        fish:void) have fish || add fish-shell ;;
        fish:*) have fish || add fish ;;
        nushell:*) have nu || add nushell ;;
        esac
        if [ -n "${SWIPTERM_SSH_PORT:-}" ] && ! have sshd; then
            case "$SWIPTERM_DISTRIBUTION" in
            arch | void) add openssh ;;
            *) add openssh-server ;;
            esac
        fi
        if want_tool build-essentials; then
            case "$SWIPTERM_DISTRIBUTION" in
            alpine) add build-base ;;
            arch | void) add base-devel ;;
            debian | devuan | kali | ubuntu) add build-essential ;;
            *) add gcc gcc-c++ make ;;
            esac
        fi
        if want_tool git && ! have git; then
            add git
        fi
        if want_tool docker; then
            case "$SWIPTERM_DISTRIBUTION" in
            alma | centos | oracle | rocky)
                add docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ca-certificates
                ;;
            alpine)
                add docker docker-openrc docker-cli-compose docker-cli-buildx
                ;;
            arch | openSUSE | void)
                add docker docker-compose docker-buildx
                ;;
            debian)
                add docker.io ca-certificates
                if [ -z "$SWIPTERM_VERSION_ID" ] || version_at_least 13; then
                    add docker-cli docker-compose docker-buildx
                fi
                ;;
            devuan)
                add docker.io ca-certificates
                if version_at_least 6; then
                    add docker-cli docker-compose docker-buildx
                fi
                ;;
            fedora)
                add moby-engine docker-cli docker-compose docker-buildx ca-certificates
                ;;
            kali)
                add docker.io docker-cli docker-compose docker-buildx ca-certificates
                ;;
            openEuler)
                add moby ca-certificates
                ;;
            ubuntu)
                add docker.io ca-certificates
                if version_at_least 24; then
                    add docker-compose-v2 docker-buildx
                fi
                ;;
            esac
        fi
        if want_tool gnupg && ! have gpg; then
            case "$SWIPTERM_DISTRIBUTION" in
            alma | centos | fedora | openEuler | oracle | rocky) add gnupg2 ;;
            openSUSE) add gpg2 ;;
            *) add gnupg ;;
            esac
        fi
        if want_tool python; then
            case "$SWIPTERM_DISTRIBUTION" in
            alpine) add python3 py3-pip ;;
            arch) add python python-pip ;;
            debian | devuan | kali | ubuntu) add python3 python3-pip python3-venv ;;
            *) add python3 python3-pip ;;
            esac
        fi
        if want_tool go && go_from_packages; then
            case "$SWIPTERM_DISTRIBUTION" in
            alma | centos | fedora | oracle | rocky) add golang ;;
            debian | kali | ubuntu) add golang-go ;;
            *) add go ;;
            esac
        fi
        if want_tool node; then
            if has_recent_packages; then
                if [ "$SWIPTERM_DISTRIBUTION" != openSUSE ]; then
                    add nodejs
                fi
                if want_tool npm; then
                    case "$SWIPTERM_DISTRIBUTION" in
                    openSUSE | void) ;;
                    *) add npm ;;
                    esac
                fi
            else
                case "$SWIPTERM_DISTRIBUTION" in
                alma | centos | fedora | openEuler | oracle | rocky) add libatomic ;;
                debian | devuan | kali | ubuntu) add libatomic1 ;;
                esac
            fi
        fi
        if [ "$SWIPTERM_DISTRIBUTION" = arch ]; then
            if want_tool pnpm; then
                add pnpm
            fi
            if want_tool bun; then
                add bun
            fi
        fi
        if [ "$SWIPTERM_DISTRIBUTION" = alpine ]; then
            have sudo || add sudo
            if want_tool pnpm || want_tool bun || want_agent claude-code; then
                add libgcc libstdc++
            fi
            if want_agent codex; then
                add ripgrep
            fi
        fi
        if downloads_upstream; then
            have curl || add curl
            have tar || add tar
            add ca-certificates
        fi
    }

    sync_packages() {
        [ -z "$packages_synced" ] || return 0
        packages_synced=1
        case "$SWIPTERM_DISTRIBUTION" in
        debian | devuan | kali | ubuntu)
            if [ ! -e /usr/sbin/policy-rc.d ]; then
                mkdir -p /usr/sbin
                printf '#!/bin/sh\n# swipterm\nexit 101\n' > /usr/sbin/policy-rc.d
                chmod 0755 /usr/sbin/policy-rc.d
                policy_rc_d=/usr/sbin/policy-rc.d
            fi
            apt-get update
            ;;
        alpine)
            apk update
            ;;
        arch)
            if [ -e /var/lib/pacman/db.lck ] && ! pgrep -x pacman >/dev/null 2>&1; then
                rm -f /var/lib/pacman/db.lck
            fi
            pacman -Sy --disable-download-timeout
            ;;
        alma | centos | fedora | openEuler | oracle | rocky)
            if [ "$SWIPTERM_DISTRIBUTION" = oracle ]; then
                dnf -y install "oraclelinux-release-el${SWIPTERM_VERSION_ID%%.*}"
            fi
            if want_tool docker; then
                case "$SWIPTERM_DISTRIBUTION" in
                alma | centos | oracle | rocky)
                    docker_repo_os=rhel
                    if [ "$SWIPTERM_DISTRIBUTION" = centos ]; then
                        docker_repo_os=centos
                    fi
                    docker_repo_ver=${SWIPTERM_VERSION_ID%%.*}
                    mkdir -p /etc/yum.repos.d
                    cat > /etc/yum.repos.d/docker-ce.repo <<EOF
    [docker-ce-stable]
    name=Docker CE Stable - \$basearch
    baseurl=https://download.docker.com/linux/$docker_repo_os/$docker_repo_ver/\$basearch/stable
    enabled=1
    gpgcheck=1
    gpgkey=https://download.docker.com/linux/$docker_repo_os/gpg
    EOF
                    ;;
                esac
            fi
            if want_tool node; then
                case "$SWIPTERM_DISTRIBUTION:${SWIPTERM_VERSION_ID%%.*}" in
                alma:9 | centos:9 | oracle:9 | rocky:9) dnf -y module enable nodejs:24 ;;
                esac
            fi
            ;;
        openSUSE)
            zypper --non-interactive refresh
            ;;
        void)
            xbps-install -Suy xbps
            ;;
        esac
    }

    install_packages() {
        sync_packages
        case "$SWIPTERM_DISTRIBUTION" in
        debian | devuan | kali | ubuntu)
            apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confold "$@"
            ;;
        alpine)
            apk add "$@"
            ;;
        arch)
            pacman -Su --noconfirm --needed --disable-download-timeout "$@"
            ;;
        alma | centos | fedora | openEuler | oracle | rocky)
            dnf -y --setopt=install_weak_deps=False install "$@"
            ;;
        openSUSE)
            zypper --non-interactive --no-refresh install --no-recommends "$@"
            ;;
        void)
            xbps-install -y "$@"
            ;;
        esac
    }

    install_opensuse_node() {
        [ "$SWIPTERM_DISTRIBUTION" = openSUSE ] && want_tool node || return 0
        step node
        if want_tool npm; then
            install_packages nodejs24 npm24
        else
            install_packages nodejs24
        fi
        for tool in node npm npx; do
            if ! have "$tool" && [ -x "/usr/bin/${tool}24" ]; then
                ln -s "${tool}24" "/usr/bin/$tool"
            fi
        done
    }

    install_go() {
        if ! want_tool go || go_from_packages; then
            return 0
        fi
        step go
        fetch "https://go.dev/dl/?mode=json" > "$work/go.json"
        archive=$(sed -n 's/.*"filename"[[:space:]]*:[[:space:]]*"\(go[^"]*\.linux-arm64\.tar\.gz\)".*/\1/p' "$work/go.json" | head -n 1)
        download "https://go.dev/dl/$archive" "$work/$archive"
        rm -rf /usr/local/go
        tar -xzf "$work/$archive" -C /usr/local
    }

    install_node() {
        if ! want_tool node || has_recent_packages; then
            return 0
        fi
        step node
        base=https://nodejs.org/dist/latest-v24.x
        fetch "$base/SHASUMS256.txt" > "$work/SHASUMS256.txt"
        archive=$(grep -o 'node-v[0-9.]*-linux-arm64\.tar\.gz$' "$work/SHASUMS256.txt" | head -n 1)
        download "$base/$archive" "$work/$archive"
        tar -xzf "$work/$archive" -C "$work"
        node=$work/${archive%.tar.gz}
        if ! want_tool npm; then
            rm -rf "$node/bin/npm" "$node/bin/npx" "$node/bin/corepack" "$node/lib/node_modules"
        fi
        cp -R "$node/bin" "$node/include" "$node/lib" "$node/share" /usr/local/
    }

    install_pnpm() {
        if ! want_tool pnpm || [ "$SWIPTERM_DISTRIBUTION" = arch ]; then
            return 0
        fi
        step pnpm
        fetch "$npm_registry/@pnpm/exe/latest" > "$work/pnpm.json"
        version=$(json_value version < "$work/pnpm.json")
        [ -n "$version" ] || fail latest_version pnpm
        npm_tarball "@pnpm/exe.linux-arm64$musl" "$version" "$work/pnpm.tgz"
        mkdir "$work/pnpm"
        tar -xzf "$work/pnpm.tgz" -C "$work/pnpm"
        install -m 0755 "$work/pnpm/package/pnpm" /usr/local/bin/pnpm
        for name in pn pnpx pnx; do
            ln -sf pnpm "/usr/local/bin/$name"
        done
    }

    install_bun() {
        if ! want_tool bun || [ "$SWIPTERM_DISTRIBUTION" = arch ]; then
            return 0
        fi
        step bun
        fetch "$npm_registry/bun/latest" > "$work/bun.json"
        version=$(json_value version < "$work/bun.json")
        [ -n "$version" ] || fail latest_version Bun
        npm_tarball "@oven/bun-linux-aarch64$musl" "$version" "$work/bun.tgz"
        mkdir "$work/bun"
        tar -xzf "$work/bun.tgz" -C "$work/bun"
        install -m 0755 "$work/bun/package/bin/bun" /usr/local/bin/bun
        ln -sf bun /usr/local/bin/bunx
    }

    install_system_packages() {
        collect_packages
        [ -n "$packages" ] || return 0
        step packages
        install_packages $packages
    }

    remove_template_user() {
        template=$1
        [ "$template" != "$user" ] || return 0
        id "$template" >/dev/null 2>&1 || return 0
        userdel -r "$template" || true
        if id "$template" >/dev/null 2>&1; then
            fail template_user "$template"
        fi
    }

    admin_group() {
        for group in wheel sudo; do
            if grep -q "^$group:" /etc/group; then
                printf '%s\n' "$group"
                return
            fi
        done
        if have groupadd; then
            groupadd --system wheel
        else
            addgroup -S wheel
        fi
        printf 'wheel\n'
    }

    shell_path() {
        name=$SWIPTERM_SHELL
        if [ "$name" = nushell ]; then
            name=nu
        fi
        for directory in /usr/bin /bin; do
            if [ -x "$directory/$name" ]; then
                printf '%s\n' "$directory/$name"
                return
            fi
        done
        fail not_installed "$name"
    }

    login_shell() {
        if [ -n "${SWIPTERM_SHELL:-}" ]; then
            shell_path
            return
        fi
        for shell in /bin/bash /bin/ash /bin/sh; do
            if [ -x "$shell" ]; then
                printf '%s\n' "$shell"
                return
            fi
        done
    }

    create_user() {
        group=$(admin_group)
        shell=$(login_shell)
        if id "$user" >/dev/null 2>&1; then
            uid=$(id -u "$user")
            if [ "$uid" -lt 1000 ] || [ "$uid" -ge 60000 ]; then
                fail system_account "$user"
            fi
        else
            if have useradd; then
                useradd --create-home --shell "$shell" "$user"
            else
                adduser -D -s "$shell" -h "/home/$user" "$user"
            fi
        fi
        join_group "$group"
        if [ -n "${SWIPTERM_PASSWORD:-}" ]; then
            printf '%s:%s\n' "$user" "$SWIPTERM_PASSWORD" | chpasswd
        elif have usermod; then
            usermod -p '*' "$user"
        else
            printf '%s:*\n' "$user" | chpasswd -e
        fi
    }

    configure_sudo() {
        have sudo || return 0
        sudoers=/etc/sudoers
        if [ ! -e "$sudoers" ] && [ -e /usr/etc/sudoers ]; then
            sudoers=/usr/etc/sudoers
        fi
        if ! grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers\.d/?[[:space:]]*$' "$sudoers"; then
            if [ "$sudoers" != /etc/sudoers ]; then
                cp "$sudoers" /etc/sudoers
                sudoers=/etc/sudoers
            fi
            printf '\n#includedir /etc/sudoers.d\n' >> /etc/sudoers
            chmod 0440 /etc/sudoers
        fi
        mkdir -p /etc/sudoers.d
        chown 0:0 /etc/sudoers.d
        chmod 0755 /etc/sudoers.d
        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$user" > /etc/sudoers.d/swipterm
        chown 0:0 /etc/sudoers.d/swipterm
        chmod 0440 /etc/sudoers.d/swipterm
        if ! visudo -cf "$sudoers"; then
            rm -f /etc/sudoers.d/swipterm
            fail rejected_configuration sudo
        fi
    }

    configure_doas() {
        have doas || return 0
        mkdir -p /etc/doas.d
        chown 0:0 /etc/doas.d
        chmod 0755 /etc/doas.d
        printf 'permit nopass %s\n' "$user" > /etc/doas.d/swipterm.conf
        chown 0:0 /etc/doas.d/swipterm.conf
        chmod 0400 /etc/doas.d/swipterm.conf
        if ! doas -C /etc/doas.d/swipterm.conf; then
            rm -f /etc/doas.d/swipterm.conf
            fail rejected_configuration doas
        fi
    }

    configure_polkit() {
        if [ -d /etc/polkit-1/rules.d ] || [ -d /usr/share/polkit-1/rules.d ]; then
            if [ ! -d /etc/polkit-1/rules.d ]; then
                mkdir -p /etc/polkit-1/rules.d
                if getent group polkitd >/dev/null 2>&1; then
                    chown 0:polkitd /etc/polkit-1/rules.d
                    chmod 0750 /etc/polkit-1/rules.d
                elif id -u polkitd >/dev/null 2>&1; then
                    chown polkitd:0 /etc/polkit-1/rules.d
                    chmod 0700 /etc/polkit-1/rules.d
                else
                    chown 0:0 /etc/polkit-1/rules.d
                    chmod 0755 /etc/polkit-1/rules.d
                fi
            fi
            cat > /etc/polkit-1/rules.d/49-swipterm.rules <<EOF
    polkit.addRule(function(action, subject) {
        if (subject.user == "$user") {
            return polkit.Result.YES;
        }
    });
    EOF
            chown 0:0 /etc/polkit-1/rules.d/49-swipterm.rules
            chmod 0644 /etc/polkit-1/rules.d/49-swipterm.rules
        fi
        if [ -d /etc/polkit-1/localauthority/50-local.d ]; then
            cat > /etc/polkit-1/localauthority/50-local.d/49-swipterm.pkla <<EOF
    [Swipterm]
    Identity=unix-user:$user
    Action=*
    ResultAny=yes
    ResultInactive=yes
    ResultActive=yes
    EOF
            chown 0:0 /etc/polkit-1/localauthority/50-local.d/49-swipterm.pkla
            chmod 0644 /etc/polkit-1/localauthority/50-local.d/49-swipterm.pkla
        fi
    }

    load_user() {
        user_home=$(getent passwd "$user" | cut -d : -f 6)
        user_group=$(id -gn "$user")
    }

    create_shell_config() {
        case "${SWIPTERM_SHELL:-}" in
        zsh)
            if [ ! -e "$user_home/.zshrc" ]; then
                printf 'autoload -Uz compinit && compinit\n' > "$user_home/.zshrc"
                chown "$user:$user_group" "$user_home/.zshrc"
            fi
            ;;
        nushell)
            as_user 'mkdir -p "$HOME/.config/nushell" && touch "$HOME/.config/nushell/env.nu" "$HOME/.config/nushell/config.nu"'
            nu_config=$user_home/.config/nushell/config.nu
            if [ -n "$SWIPTERM_TOOLS$SWIPTERM_AGENTS" ] && [ ! -s "$nu_config" ]; then
                cat > "$nu_config" <<'EOF'
    $env.PNPM_HOME = ($env.HOME | path join ".local" "share" "pnpm")
    $env.PATH = ($env.PATH | split row (char esep) | prepend [
        ($env.HOME | path join ".local" "bin")
        ($env.HOME | path join ".bun" "bin")
        ($env.HOME | path join ".cargo" "bin")
        $env.PNPM_HOME
        ($env.PNPM_HOME | path join "bin")
        ($env.HOME | path join "go" "bin")
        "/usr/local/go/bin"
    ] | uniq)
    EOF
            fi
            if ! grep -qF /run/host-bin "$nu_config"; then
                printf '%s\n' '$env.PATH = ($env.PATH | split row (char esep) | append "/run/host-bin" | uniq)' >> "$nu_config"
            fi
            if ! grep -qF WAYLAND_DISPLAY "$nu_config"; then
                printf '%s\n' '$env.WAYLAND_DISPLAY = ($env.WAYLAND_DISPLAY? | default "/run/host/wayland-0")' >> "$nu_config"
            fi
            ;;
        esac
    }

    configure_account() {
        if [ "$user" != root ]; then
            step account
            case "$SWIPTERM_DISTRIBUTION" in
            ubuntu)
                if [ "$user" != ubuntu ]; then
                    remove_template_user ubuntu
                    rm -f /etc/sudoers.d/90-cloud-init-users
                fi
                ;;
            arch) remove_template_user alarm ;;
            esac
            create_user
            configure_sudo
            configure_doas
            configure_polkit
            if have loginctl; then
                mkdir -p /var/lib/systemd/linger
                : > "/var/lib/systemd/linger/$user"
            fi
        elif [ -n "${SWIPTERM_PASSWORD:-}" ]; then
            step account
            printf 'root:%s\n' "$SWIPTERM_PASSWORD" | chpasswd
        fi
    }

    configure_shell() {
        step shell
        configure_login_shell
        configure_path
    }

    configure_login_shell() {
        [ -n "${SWIPTERM_SHELL:-}" ] || return 0
        shell=$(shell_path)
        if [ -f /etc/shells ] && ! grep -qx "$shell" /etc/shells; then
            printf '%s\n' "$shell" >> /etc/shells
        fi
        if [ "$(getent passwd "$user" | cut -d : -f 7)" != "$shell" ]; then
            if have usermod; then
                usermod -s "$shell" "$user"
            else
                sed -i "s|^\($user:\([^:]*:\)\{5\}\)[^:]*\$|\1$shell|" /etc/passwd
            fi
        fi
        create_shell_config
    }

    configure_ssh() {
        [ -n "${SWIPTERM_SSH_PORT:-}" ] || return 0
        step ssh
        mkdir -p /run/sshd
        ssh-keygen -A
        sshd_bin=$(command -v sshd)
        password=$SWIPTERM_SSH_PASSWORD_AUTHENTICATION
        pubkey=$SWIPTERM_SSH_PUBKEY_AUTHENTICATION
        {
            printf 'Port %s\n' "$SWIPTERM_SSH_PORT"
            printf 'PasswordAuthentication %s\n' "$password"
            printf 'KbdInteractiveAuthentication %s\n' "$password"
            printf 'ChallengeResponseAuthentication %s\n' "$password"
            printf 'PubkeyAuthentication %s\n' "$pubkey"
            if [ "$user" = root ] && [ "$password" = yes ]; then
                printf 'PermitRootLogin yes\n'
            elif [ "$user" = root ]; then
                printf 'PermitRootLogin prohibit-password\n'
            fi
        } > "$work/sshd_swipterm"
        if [ -f /etc/ssh/sshd_config ] &&
            ! grep -Eq '^[[:space:]]*Include[[:space:]]+"?/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
            directives='Port|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication'
            if [ "$user" = root ]; then
                directives="$directives|PermitRootLogin"
            fi
            sed -i -E "s/^[[:space:]]*($directives)[[:space:]=]/#&/" /etc/ssh/sshd_config
            { cat "$work/sshd_swipterm"; printf '\n'; cat /etc/ssh/sshd_config; } > "$work/sshd_config"
            cat "$work/sshd_config" > /etc/ssh/sshd_config
        else
            if [ -f /etc/ssh/sshd_config ]; then
                sed -i -E 's/^[[:space:]]*Port[[:space:]=]/#&/' /etc/ssh/sshd_config
            fi
            mkdir -p /etc/ssh/sshd_config.d
            cat "$work/sshd_swipterm" > /etc/ssh/sshd_config.d/10-swipterm.conf
        fi
        if [ "$pubkey" = yes ] && [ -n "${SWIPTERM_SSH_AUTHORIZED_KEYS:-}" ]; then
            mkdir -p "$user_home/.ssh"
            printf '%s\n' "$SWIPTERM_SSH_AUTHORIZED_KEYS" > "$user_home/.ssh/authorized_keys"
            chmod 0700 "$user_home/.ssh"
            chmod 0600 "$user_home/.ssh/authorized_keys"
            chown -R "$user:$user_group" "$user_home/.ssh"
        fi
        if ! "$sshd_bin" -t; then
            fail rejected_configuration sshd
        fi
        case "$SWIPTERM_DISTRIBUTION:$SWIPTERM_VERSION_ID" in
        ubuntu:2[0-3].* | debian:* | kali:*)
            systemctl enable ssh.service
            ;;
        ubuntu:*)
            systemctl enable ssh.socket
            ;;
        devuan:*)
            update-rc.d ssh defaults
            ;;
        alpine:*)
            rc-update add sshd default
            ;;
        void:*)
            mkdir -p /etc/runit/runsvdir/default
            ln -sfn /etc/sv/sshd /etc/runit/runsvdir/default/sshd
            ;;
        *)
            systemctl enable sshd.service
            ;;
        esac
    }

    configure_docker() {
        want_tool docker || return 0
        step docker
        ensure_group docker
        if [ "$user" != root ]; then
            join_group docker
        fi
        case "$SWIPTERM_DISTRIBUTION" in
        alpine)
            rc-update add docker default
            ;;
        devuan)
            update-rc.d docker defaults
            ;;
        void)
            mkdir -p /etc/runit/runsvdir/default
            ln -sfn /etc/sv/containerd /etc/runit/runsvdir/default/containerd
            ln -sfn /etc/sv/docker /etc/runit/runsvdir/default/docker
            ;;
        *)
            systemctl enable docker.service
            ;;
        esac
    }

    configure_path() {
        case "$SWIPTERM_DISTRIBUTION" in
        debian | devuan | kali | ubuntu)
            if [ -e /etc/zsh/zprofile ] || have zsh; then
                line='emulate sh -c '\''for swipterm_profile in /etc/profile.d/*.sh; do [ -r "$swipterm_profile" ] && . "$swipterm_profile"; done; unset swipterm_profile'\'
                mkdir -p /etc/zsh
                if ! grep -qxF "$line" /etc/zsh/zprofile 2>/dev/null; then
                    printf '%s\n' "$line" >> /etc/zsh/zprofile
                fi
            fi
            ;;
        esac
        if [ -z "$SWIPTERM_TOOLS$SWIPTERM_AGENTS" ]; then
            return 0
        fi
        mkdir -p /etc/profile.d /etc/fish/conf.d
        cat > /etc/profile.d/swipterm.sh <<'EOF'
    PNPM_HOME="$HOME/.local/share/pnpm"
    export PNPM_HOME
    for swipterm_path in /usr/local/go/bin "$HOME/go/bin" "$PNPM_HOME/bin" "$PNPM_HOME" "$HOME/.bun/bin" "$HOME/.cargo/bin" "$HOME/.local/bin"; do
        case ":$PATH:" in
        *":$swipterm_path:"*) ;;
        *) PATH="$swipterm_path:$PATH" ;;
        esac
    done
    unset swipterm_path
    export PATH
    EOF
        cat > /etc/fish/conf.d/swipterm.fish <<'EOF'
    set -gx PNPM_HOME $HOME/.local/share/pnpm
    for swipterm_path in /usr/local/go/bin $HOME/go/bin $PNPM_HOME/bin $PNPM_HOME $HOME/.bun/bin $HOME/.cargo/bin $HOME/.local/bin
        contains -- $swipterm_path $PATH
        or set -gx PATH $swipterm_path $PATH
    end
    EOF
    }

    write_user_config() {
        printf '    ~/%s\n' "$1"
        as_user "mkdir -p \"\$HOME/$(dirname "$1")\" && cat > \"\$HOME/$1\""
    }

    install_rust() {
        if ! want_tool rust; then
            return 0
        fi
        step rust
        target=aarch64-unknown-linux-gnu
        if [ "$SWIPTERM_DISTRIBUTION" = alpine ]; then
            target=aarch64-unknown-linux-musl
        fi
        download "https://static.rust-lang.org/rustup/dist/$target/rustup-init" "$work/rustup-init"
        rustup_dir=$(mktemp -d /tmp/swipterm-rustup.XXXXXX)
        chown "$user:$user_group" "$rustup_dir"
        install -m 0755 "$work/rustup-init" "$rustup_dir/rustup-init"
        as_user "\"$rustup_dir/rustup-init\" -y --profile minimal --no-modify-path"
        rm -rf "$rustup_dir"
    }

    install_antigravity() {
        if ! want_agent antigravity; then
            return 0
        fi
        step antigravity
        platform=linux_arm64
        if [ "$SWIPTERM_DISTRIBUTION" = alpine ]; then
            platform=linux_arm64_musl
        fi
        fetch "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/$platform.json" > "$work/antigravity.json"
        download "$(json_value url < "$work/antigravity.json")" "$work/antigravity.tar.gz"
        mkdir "$work/antigravity"
        tar -xzf "$work/antigravity.tar.gz" -C "$work/antigravity"
        as_user 'mkdir -p "$HOME/.local/bin"'
        install -m 0755 -o "$user" -g "$user_group" "$work/antigravity/antigravity" "$user_home/.local/bin/agy"
        as_user '"$HOME/.local/bin/agy" install'
    }

    install_codex() {
        if ! want_agent codex; then
            return 0
        fi
        step codex
        fetch "$npm_registry/@openai/codex/latest" > "$work/codex.json"
        version=$(json_value version < "$work/codex.json")
        [ -n "$version" ] || fail latest_version Codex
        npm_tarball @openai/codex "$version-linux-arm64" "$work/codex.tgz"
        standalone=$user_home/.codex/packages/standalone
        release=$standalone/releases/$version-aarch64-unknown-linux-musl
        as_user "mkdir -p \"$release\" \"\$HOME/.local/bin\" &&
            tar -xzf - -C \"$release\" --strip-components=3 &&
            ln -sfn \"$release\" \"$standalone/current\" &&
            ln -sf \"$standalone/current/bin/codex\" \"\$HOME/.local/bin/codex\"" < "$work/codex.tgz"
        if [ "$SWIPTERM_DISTRIBUTION" = alpine ]; then
            as_user "ln -sf /usr/bin/rg \"$release/codex-path/rg\""
        fi
        write_user_config .codex/config.toml <<'EOF'
    check_for_update_on_startup = false

    [features]
    daemon_auto_start = false
    EOF
    }

    install_claude_code() {
        want_agent claude-code || return 0
        step claude_code
        if want_tool pnpm; then
            as_user "pnpm add --global --allow-build=@anthropic-ai/claude-code @anthropic-ai/claude-code"
        elif want_tool bun; then
            as_user "bun add --global --trust @anthropic-ai/claude-code"
        else
            as_user "npm install --global --prefix \"\$HOME/.local\" @anthropic-ai/claude-code"
        fi
    }

    clean_caches() {
        step cleanup
        case "$SWIPTERM_DISTRIBUTION" in
        debian | devuan | kali | ubuntu) apt-get clean ;;
        arch) rm -rf /var/cache/pacman/pkg/* ;;
        void) rm -rf /var/cache/xbps/* ;;
        esac
        if want_agent claude-code && ! want_tool pnpm; then
            if want_tool bun; then
                as_user "bun pm cache rm"
            else
                as_user "npm cache clean --force"
            fi
        fi
    }

    case "$user" in
    root) ;;
    "" | -* | *[!A-Za-z0-9._-]*) fail invalid_username "$user" ;;
    esac

    if [ -z "$SWIPTERM_DISTRIBUTION" ] &&
        [ -n "${SWIPTERM_SHELL:-}${SWIPTERM_SSH_PORT:-}$SWIPTERM_TOOLS$SWIPTERM_AGENTS" ]; then
        warn unrecognized_distribution
        SWIPTERM_SHELL='' SWIPTERM_SSH_PORT='' SWIPTERM_TOOLS='' SWIPTERM_AGENTS=''
    fi
    tools=" $SWIPTERM_TOOLS "
    agents=" $SWIPTERM_AGENTS "
    musl=
    if [ "$SWIPTERM_DISTRIBUTION" = alpine ]; then
        musl=-musl
    fi
    npm_registry=https://registry.npmjs.org
    packages_synced=

    if [ "$SWIPTERM_DISTRIBUTION" = oracle ] && [ -f /etc/pki/rpm-gpg/RPM-GPG-KEY-oracle ]; then
        sed -i 's|file:///RPM-GPG-KEY-oracle|file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle|' /etc/yum.repos.d/*.repo
    fi
    stage reconcile_kernel
    case "$SWIPTERM_DISTRIBUTION" in
    arch)
        stage generate_locale
        stage init_keyring
        ;;
    alma | centos | fedora | openEuler | oracle | rocky) prepare_dnf ;;
    esac

    if [ -n "$SWIPTERM_DISTRIBUTION" ]; then
        stage install_system_packages
        stage install_opensuse_node
        stage install_go
        stage install_node
        stage install_pnpm
        stage install_bun
    fi

    stage configure_account
    load_user
    stage configure_shell
    stage configure_ssh
    stage configure_docker
    stage install_rust
    stage install_claude_code
    stage install_codex
    stage install_antigravity
    stage clean_caches
    rm -f "$progress"
    """#
}
