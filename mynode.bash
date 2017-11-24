#!/bin/bash

declare __mynode_prefix_dir
declare __mynode_bin_dir
declare __mynode_node_dir
declare __mynode_cache_dir
declare __mynode_arch


__mynode_log_info() { printf -- "mynode: %s\n" "$1" >&2; }


__mynode_log_error() { printf -- "mynode: Error! %s\n" "$1" >&2; }


__mynode_log_warn() { printf -- "mynode: Warning! %s\n" "$1" >&2; }


__mynode_tac() {
	local input i
	readarray input
	for (( i=(${#input[@]} - 1); i >= 0; --i )); do
		printf -- "%s" "${input[$i]}"
	done
}


__mynode_is_sourced() {
	if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
		return 0
	else
		return 1
	fi
}


__mynode_trim() {
	local var="$*"
	var="${var#${var%%[![:space:]]*}}"
	var="${var%${var##*[![:space:]]}}"
	printf -- "%s" "$var"
}


__mynode_config_defaults() {
	[[ $(__mynode_trim "$__mynode_prefix_dir") ]] || __mynode_prefix_dir="$HOME/.local"
	[[ $(__mynode_trim "$__mynode_bin_dir")    ]] || __mynode_bin_dir="$__mynode_prefix_dir/bin"
	[[ $(__mynode_trim "$__mynode_node_dir")   ]] || __mynode_node_dir="$__mynode_prefix_dir/lib/node"
	[[ $(__mynode_trim "$__mynode_cache_dir")  ]] || __mynode_cache_dir="$HOME/.cache/mynode"
	[[ $(__mynode_trim "$__mynode_arch")       ]] || __mynode_arch="linux-x64"
}


__mynode_read_config() {
	if [[ -f "$HOME/.config/mynode/initrc" ]]; then
		local k v
		while IFS="=" read -r k v; do
			k="$(__mynode_trim "$k")"
			v="$(__mynode_trim "$v")"

			if [[ ${v#\"} != "$v" && "${v%\"}" != "$v" ]]; then
				v="${v#\"}"; v="${v%\"}"
			elif [[ ${v#\'} != "$v" && "${v%\'}" != "$v" ]]; then
				v="${v#\'}"; v="${v%\'}"
			fi

			case "$k" in
				prefix_dir | bin_dir | node_dir | cache_dir)
					v="${v%/}"
					v="${v//\~/$HOME}"
					read -r -d '' "__mynode_$k" <<< "$v"
					;;
				arch)
					read -r -d '' "__mynode_$k" <<< "$v"
					;;
				"#"*)
					;;
			esac
		done < "$HOME/.config/mynode/initrc"
	fi

	__mynode_config_defaults
}


__mynode_update() {
	(
		cd "$__mynode_cache_dir" || return 1
		if ! curl -O -s -L "http://nodejs.org/dist/index.tab"; then
			__mynode_log_error "Updating failed!"
			return 1
		fi
	)
}


__mynode_update_links() {
	local IFS latest latest_lts
	local version date files npm v8 uv zlib openssl modules lts

	if [[ ! -f $__mynode_cache_dir/index.tab ]]; then
		__mynode_update || return $?
	fi

	rm -f "$__mynode_node_dir/latest"
	rm -f "$__mynode_node_dir/lts"

	if [[ -L $__mynode_node_dir/current ]]; then
		if [[ ! -d $(cd "$__mynode_node_dir/current" &> /dev/null && pwd -P) ]]; then
			rm -f "$__mynode_node_dir/current"
		fi
	fi

	# shellcheck disable=2030
	while IFS=$'\t' read -r version date files npm v8 uv zlib openssl modules lts; do
		if [[ $version == version ]]; then
			continue
		fi
		version="${version#v}"
		local IFS=,
		for file in $files; do
			if [[ $file == "$__mynode_arch" ]]; then
				if [[ ! $latest ]]; then
					latest="$version"
				fi
				if [[ ! $latest_lts && $lts != - ]]; then
					latest_lts="$version"
				fi

				local dirname="v$version"
				local dirpath="$__mynode_node_dir/$dirname"

				if [[ -d $dirpath ]]; then
					if [[ $version == "$latest" ]]; then
						ln -sTf "$dirname" "$__mynode_node_dir/latest"
					fi
					if [[ $version == "$latest_lts" ]]; then
						ln -sTf "$dirname" "$__mynode_node_dir/lts"
					fi
				fi

				break
			fi
		done
		if [[ $version == 4.0.0 ]]; then
			return 0
		fi
	done < "$__mynode_cache_dir/index.tab"
}


__mynode_install() {
	# shellcheck disable=2031
	local requested_version="${1:?Specify node version}"
	local version date files npm v8 uv zlib openssl modules lts

	if ! [[ -f index.tab ]]; then
		__mynode_update || return $?
	fi

	while IFS=$'\t' read -r version date files npm v8 uv zlib openssl modules lts; do
		if [[ $version == version ]]; then
			continue
		fi
		version="${version#v}"

		local IFS=,
		for file in $files; do
			if [[ $file == "$__mynode_arch" ]]; then
				if [[ $requested_version == latest ]] ||
					[[ $requested_version == lts && $lts != - ]] ||
					[[ $requested_version == "$version" ]]; then
					local dirname="v$version"
					local dirpath="$__mynode_node_dir/$dirname"
					if [[ -d $dirpath ]]; then
						__mynode_log_warn "Version $requested_version ($version) already installed"
						return 0
					fi
					local filename="node-v$version-$__mynode_arch.tar.xz"
					__mynode_log_info "Downloading $requested_version ($version)"
					(
						cd "$__mynode_cache_dir" || return 1
						if ! curl -s -L -O -C - "http://nodejs.org/dist/v$version/$filename"; then
							__mynode_log_error "Downloading version $version failed!"
							return 1
						fi
					)
					mkdir -p "$dirpath"
					if ! tar xJf "$filename" -C "$dirpath" --strip-components=1; then
						__mynode_log_error "Opening archive $version failed!"
						return 1
					fi
					return 0
				fi
				break
			fi
		done
		if [[ $version == 4.0.0 ]]; then
			return 0
		fi
	done < "$__mynode_cache_dir/index.tab"
	__mynode_log_error "Node version $requested_version not found!"
	return 1
}


__mynode_list() {
	local IFS latest_lts=f
	local version date files npm v8 uv zlib openssl modules lts
	local current
	current="$(cd "$__mynode_node_dir/current" &> /dev/null && pwd -P)"
	current="${current##*/v}"

	if ! [[ -f index.tab ]]; then
		__mynode_update || return $?
	fi

	while IFS=$'\t' read -r version date files npm v8 uv zlib openssl modules lts; do
		if [[ $version == version ]]; then
			continue
		fi

		version="${version#v}"

		local IFS=,
		for file in $files; do
			if [[ $file != "$__mynode_arch" ]]; then
				continue
			fi

			printf -- "%8s" "$version"

			if [[ -d $__mynode_node_dir/v$version ]]; then
				printf -- "%s" "*"
			else
				printf -- "%s" " "
			fi

			if [[ $lts != - && $latest_lts != t ]]; then
				latest_lts=t
				printf -- "%4s" "lts"
			else
				printf -- "%4s" " "
			fi

			if [[ $current == "$version" ]]; then
				printf -- " %s" "<-- current"
			fi

			printf -- "\n"
		done
		if [[ $version == 4.0.0 ]]; then
			return 0
		fi
	done < "$__mynode_cache_dir/index.tab" | __mynode_tac
}


__mynode_get() {
	local version
	version="$(__mynode_trim "$1")"
	local dirname dirpath
	if [[ $version == latest || $version == lts ]]; then
		dirname="$(cd "$__mynode_node_dir/$version" &> /dev/null && pwd -P)"
		dirname="${dirname##*/}"
		dirpath="$__mynode_node_dir/$dirname"
	else
		version="${version##*/}"
		if [[ $version != "$1" || $version == "" ]]; then
			__mynode_log_error "Invalid version specified!"
			return 1
		fi
		dirname="v$version"
		dirpath="$__mynode_node_dir/$dirname"
	fi

	if [[ ! -d $dirpath ]]; then
		__mynode_log_error "Version $version not installed!"
		return 1
	fi

	printf -- "%s\n" "$dirpath"
}


__mynode_uninstall() {
	local version="$1"
	local dirpath

	if ! dirpath="$(__mynode_get "$version")"; then
		return $?
	fi

	rm -rf "$__mynode_node_dir/v$version"
}


__mynode_unset() {
	# shellcheck disable=2155
	export PATH="$(__mynode_path_clean "$PATH")"
	# shellcheck disable=2155
	export MANPATH="$(__mynode_path_clean "${MANPATH:-:}")"
	# shellcheck disable=2155
	export CPATH="$(__mynode_path_clean "$CPATH")"
}


__mynode_set() {
	local version="$1"
	local dirpath

	if ! dirpath="$(__mynode_get "$version")"; then
		return $?
	fi

	# shellcheck disable=2155
	export PATH="$(__mynode_path_prepend "$dirpath/bin" "$PATH")"
	# shellcheck disable=2155
	export MANPATH="$(__mynode_path_prepend "$dirpath/share/man" "${MANPATH:-:}")"
	# shellcheck disable=2155
	export CPATH="$(__mynode_path_prepend "$dirpath/include" "$CPATH")"
}


__mynode_use() {
	local version="$1"
	local dirpath

	if ! dirpath="$(__mynode_get "$version")"; then
		return $?
	fi

	ln -sTf "${dirpath##*/}" "$__mynode_node_dir/current"
}


__mynode_setup() {
	[[ -d $__mynode_prefix_dir ]] && mkdir -p "$__mynode_prefix_dir"
	[[ -d $__mynode_bin_dir ]] && mkdir -p "$__mynode_bin_dir"
	[[ -d $__mynode_node_dir ]] && mkdir -p "$__mynode_node_dir"
	[[ -d $__mynode_cache_dir ]] && mkdir -p "$__mynode_cache_dir"

	local this_dir
	this_dir="$(cd "${0%/*}" &> /dev/null && pwd -P)"
	if [[ -L $__mynode_bin_dir/mynode ]]; then
		__mynode_log_info "$__mynode_bin_dir/mynode -> $this_dir/mynode.bash"
		ln -sTf "$this_dir/mynode.bash" "$__mynode_bin_dir/node"
	fi
	if [[ -L $__mynode_bin_dir/node ]]; then
		__mynode_log_info "$__mynode_bin_dir/node -> $__mynode_node_dir/current/bin/node"
		ln -sTf "$__mynode_node_dir/current/bin/node" "$__mynode_bin_dir/node"
	fi
	if [[ -L $__mynode_bin_dir/node@current ]]; then
		__mynode_log_info "$__mynode_bin_dir/node@current -> $__mynode_node_dir/current/bin/node"
		ln -sTf "$__mynode_node_dir/current/bin/node" "$__mynode_bin_dir/node@current"
	fi
	if [[ -L $__mynode_bin_dir/npm@current ]]; then
		__mynode_log_info "$__mynode_bin_dir/npm@current -> $__mynode_node_dir/current/bin/npm"
		ln -sTf "$__mynode_node_dir/current/bin/npm" "$__mynode_bin_dir/npm@current"
	fi
	if [[ -L $__mynode_bin_dir/npx@current ]]; then
		__mynode_log_info "$__mynode_bin_dir/npx@current -> $__mynode_node_dir/current/bin/npx"
		ln -sTf "$__mynode_node_dir/current/bin/npx" "$__mynode_bin_dir/npx@current"
	fi

	"$__mynode_node_dir/current/bin/npm" config set prefix "$__mynode_prefix_dir"
	"$__mynode_node_dir/current/bin/npm" install -g npm
}


__mynode_clean() {
	if [[ $__mynode_cache_dir ]]; then
		rm -rf "$__mynode_cache_dir"
		mkdir -p "$__mynode_cache_dir"
	fi
}


__mynode_path_clean() {
	local path new_path path_dir
	if [[ $# -lt 1 ]]; then
		path="$PATH"
	else
		path="$1"
	fi
	while read -r -d ':' path_dir; do
		if [[ ${path_dir#$__mynode_node_dir} == "$path_dir" ]]; then
			new_path+=":${path_dir}"
		fi
	done <<< "${path}:"
	printf -- "%s" "${new_path#:}"
}


__mynode_path_prepend() {
	local dir="${1:?Missing path}"
	local path
	if [[ $# -lt 2 ]]; then
		path="$PATH"
	else
		path="$2"
	fi
	path="$(__mynode_path_clean "$path")"
	case "$path" in
		:)  printf -- "%s:" "$dir" ;;
		"") printf -- "%s" "$dir" ;;
		*)  printf -- "%s:%s" "$dir" "$path" ;;
	esac
}


__mynode_list_index() {
	local IFS
	local version date files npm v8 uv zlib openssl modules lts
	# shellcheck disable=2034
	while IFS=$'\t' read -r version date files npm v8 uv zlib openssl modules lts; do
		if [[ $version == version ]]; then
			continue
		fi
		version="${version#v}"
		IFS=,
		for file in $files; do
			if [[ $file != "$__mynode_arch" ]]; then
				continue
			fi
			printf -- "%s\n" "$version"
		done
		if [[ $version == 4.0.0 ]]; then
			return 0
		fi
	done < "$__mynode_cache_dir/index.tab" | __mynode_tac
}


__mynode_list_installed() {
	for dir in "$__mynode_node_dir/v"*/; do
		dir="${dir%/}"
		dir="${dir##*/}"
		if [[ $dir == "*" ]]; then
			return 0
		fi
		printf -- "%s\n" "${dir#v}"
	done
}


__mynode_complete() {
	local cur_word prev_word word_list
	cur_word="${COMP_WORDS[COMP_CWORD]}"
	prev_word="${COMP_WORDS[COMP_CWORD-1]}"

	if [[ $COMP_CWORD == 1 ]]; then
		word_list="install uninstall use list ls update clean"
		# shellcheck disable=2086
		COMPREPLY=( $(compgen -W "${word_list}" -- ${cur_word}) )

	elif [[ $COMP_CWORD == 2 ]]; then
		case "$prev_word" in
			install)
				# shellcheck disable=2086
				COMPREPLY=( $(compgen -W "$(__mynode_list_index)" -- ${cur_word}) )
				;;
			uninstall|set|use|get)
				# shellcheck disable=2086
				COMPREPLY=( $(compgen -W "$(__mynode_list_installed)" -- ${cur_word}) )
				;;
		esac
	fi

	return 0
}


mynode() {
	__mynode_read_config

	local command="$1"
	case "$command" in
		install)
			shift
			__mynode_install "$@" && __mynode_update_links
			;;
		uninstall)
			shift
			__mynode_uninstall "$@" && __mynode_update_links
			;;
		update)
			__mynode_update && __mynode_update_links
			;;
		list|ls)
			__mynode_list
			;;
		clean)
			__mynode_clean
			;;
		use)
			shift
			__mynode_use "$@"
			;;
		get)
			shift
			__mynode_get "$@"
			;;
		set)
			shift
			if ! __mynode_is_sourced; then
				__mynode_log_warn "Command \"set\" is effective only if mynode is sourced"
			fi
			__mynode_set "$@"
			;;
		unset)
			if ! __mynode_is_sourced; then
				__mynode_log_warn "Command \"unset\" is effective only if mynode is sourced"
			fi
			__mynode_unset
			;;

		*)
			cat << EOF
mynode [command]
Available commands:
  install {version}
  uninstall {version}
  list | ls
  update
  clean
  use {version}
  get {version}
  set {version}    (effective only if mynode is sourced)
  unset            (effective only if mynode is sourced)

Where {version} can be one of "latest", "lts" or "{mayor}.{minor}.{patch}"

Configuration:
  prefix_dir = "$__mynode_prefix_dir"
     bin_dir = "$__mynode_bin_dir"
    node_dir = "$__mynode_node_dir"
   cache_dir = "$__mynode_cache_dir"
        arch = "$__mynode_arch"
EOF
			;;
	esac
}


__mynode_main_setup() {
	__mynode_read_config

	local command="$1"
	case "$command" in
		setup)
			__mynode_setup
			;;
		*)
			cat << EOF
mynode [command]
Available commands:
  setup

Configuration:
  prefix_dir = "$__mynode_prefix_dir"
     bin_dir = "$__mynode_bin_dir"
    node_dir = "$__mynode_node_dir"
   cache_dir = "$__mynode_cache_dir"
        arch = "$__mynode_arch"
EOF
			;;
	esac
}


# execute mynode in setup mode (not sourced and in the repository directory)
if [[ ${0##*/} == mynode.bash ]]; then
	__mynode_main_setup "$@"

# load mynode silently when there are no parameters in sourced mode
elif __mynode_is_sourced && [[ $# == 0 ]]; then
	complete -o nosort -F __mynode_complete mynode

# execute mynode (sourced or normal mode)
else
	mynode "$@"
fi
