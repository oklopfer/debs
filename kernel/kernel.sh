#!/usr/bin/env bash

# Colors
if [[ -z $NO_COLOR ]]; then
  export NC=$'\033[0m'
  export BGreen=$'\033[1;32m'
  export BCyan=$'\033[1;36m'
  export BYellow=$'\033[1;33m'
  export BPurple=$'\033[1;35m'
  export BRed=$'\033[1;31m'
  export BWhite=$'\033[1;37m'
fi

if [[ ! -d .git || $(basename `git rev-parse --show-toplevel`) != "pacstall-programs" ]]; then
  echo "${BRed}ERROR${NC}: not in a ${BCyan}pacstall-programs${NC} git clone."
  exit 1
fi

function ask() {
    local prompt default reply

    if [[ ${2-} == 'Y' ]]; then
        prompt="${BGreen}Y${NC}/${BRed}n${NC}"
        default='Y'
    elif [[ ${2-} == 'N' ]]; then
        prompt="${BGreen}y${NC}/${BRed}N${NC}"
        default='N'
    else
        prompt="${BGreen}y${NC}/${BRed}n${NC}"
    fi

    # Ask the question (not using "read -p" as it uses stderr not stdout)
    echo -ne "$1 [$prompt] "

    if [[ ${DISABLE_PROMPTS:-z} == "z" ]]; then
        export DISABLE_PROMPTS="no"
    fi

    if [[ $DISABLE_PROMPTS == "no" ]]; then
        read -r reply <&0
        # Detect if script is running non-interactively
        # Which implies that the input is being piped into the script
        if [[ $NON_INTERACTIVE ]]; then
            if [[ -z $reply ]]; then
                echo -n "$default"
            fi
            echo "$reply"
        fi
    else
        echo "$default"
        reply=$default
    fi

    # Default?
    if [[ -z $reply ]]; then
        reply=$default
    fi

    while :; do
        # Check if the reply is valid
        case "$reply" in
            Y* | y*)
                export answer=1
                return 0 #return code for backwards compatibility
                break
                ;;
            N* | n*)
                export answer=0
                return 1 #return code
                break
                ;;
            *)
                echo -ne "$1 [$prompt] "
                read -r reply < /dev/tty
                ;;
        esac
    done
}

function fetch_kver() {
  local keroutput
  keroutput=$(curl -fsSL "https://kernel.ubuntu.com/mainline/v${kerver}/amd64/CHECKSUMS" 2> /dev/null | grep 'Sha256' -A 4 | grep -v 'Sha256' && \
  curl -fsSL "https://kernel.ubuntu.com/mainline/v${kerver}/arm64/CHECKSUMS" 2> /dev/null | grep 'Sha256' -A 6 | grep -v 'Sha256' | grep -v '64k')
  mapfile -t input_data <<< "${keroutput}"
  input_data+=("EOF")
  if [[ -z ${input_data[7]} ]]; then
    echo "${BRed}ERROR${NC}: incomplete ${BCyan}version${NC} response from server."
    exit 1
  fi
}

function parse_filename() {
  local filename=$1
  local name

  if [[ $filename == *"linux-modules"* ]]; then
    name="linux-modules"
  elif [[ $filename == *"linux-headers"* ]]; then
    name="linux-headers"
    [[ $filename == *"-generic"* ]] && name+="-generic"
  elif [[ $filename == *"linux-image-unsigned"* ]]; then
    name="linux-image-unsigned"
  fi

  if $stable; then
    name+="-stable"
  fi

  echo "${name}-deb"
}

function update_ker() {
  if [[ -z ${stable} ]]; then
    ask "Are you updating stable kernel packages?" N
    if ((answer == 0)); then
        stable=false
    else
        stable=true
    fi
  fi

  if [[ -z ${input_data[*]} ]]; then
    echo "Paste file inputs (${BPurple}type EOF when done${NC}):"
    input_data=()
    while IFS= read -r line; do
      [[ $line == "EOF" ]] && break
      input_data+=("$line")
    done
  fi

  for line in "${input_data[@]}"; do
    IFS=' ' read -r -a arr <<<"$line"
    [[ ${arr[0]} == "EOF" ]] && break
    hash=${arr[0]}
    package=${arr[1]}

    if [[ $package == *"rc"* ]]; then
      if ${stable}; then
        echo "${BYellow}WARNING${NC}: ${BPurple}stable${NC} cannot be an ${BCyan}rc${NC} release, switching to ${BPurple}mainline${NC}."
        stable=false
      fi
      buildver=$(echo "$package" | perl -nle'print $& if m{([0-9]+\.[0-9]+\.?[0-9]*-?[0-9]*rc?[0-9]*\.[0-9]+)}')
    else
      buildver=$(echo "$package" | perl -nle'print $& if m{([0-9]+\.[0-9]+(-rc[0-9]+)?\.[0-9]+-[0-9]+\.?[0-9]*\.?[0-9]*\.[0-9]*)}')
    fi
    gives=$(echo "$package" | perl -nle'print $& if m{(linux-.+?)_}')
    gives=${gives%_}
    if [[ $package == *"rc"* ]]; then
      pkgver=$(echo "$gives" | perl -nle'print $& if m{([0-9]+\.[0-9]+)}') # Get the first set of numbers
      rc_number="$(echo "$package" | perl -nle'print $& if m{(rc[0-9]+)}')" # Get the 'rc' string
      if [[ -n ${rc_number} ]]; then
        pkgver+="~${rc_number}" # Append "~rc#" to pkgver
      fi
      if [[ $pkgver == *".0" ]]; then
        pkgver=${pkgver%.0}
      fi
    else
      pkgver=$(echo "$package" | perl -nle'print $& if m{([0-9]+\.[0-9]+\.[0-9]+)}')
      if [[ $pkgver == *".0" ]]; then
        pkgver=${pkgver%.0}
      fi
    fi
    if ! $stable; then
      if [[ $pkgver =~ ^[0-9]+\.[0-9]+\.[1-9][0-9]*$ ]]; then
        echo "${BYellow}WARNING${NC}: ${BPurple}mainline${NC} cannot be an ${BWhite}X.X.${BRed}X${NC} release ending with ${BCyan}1-9${NC}, switching to ${BPurple}stable${NC}."
        stable=true
      fi
    fi

    if ${newbranch} && [[ ${line} == "${input_data[0]}" ]]; then
      case ${kerselected} in
        both) gitker_branch="${pkgver}a" ;;
        stab) gitker_branch="${pkgver}s" ;;
        main) gitker_branch="${pkgver}" ;;
      esac
      if git branch | grep "${gitker_branch}" >> /dev/null && [[ $(git rev-parse --abbrev-ref HEAD) != "${gitker_branch}" ]]; then
        git branch -D ${gitker_branch/\~/}
      fi
      git checkout -b ${gitker_branch/\~/}
    fi

    pacscript=$(parse_filename "$package")

    old_pkgver=$(perl -nle'print $& if m{(?<=pkgver=").*?(?=")}' "packages/$pacscript/$pacscript.pacscript")
    old_buildver=$(perl -nle'print $& if m{(?<=buildver=").*?(?=")}' "packages/$pacscript/$pacscript.pacscript")
    old_gives=$(perl -nle'print $& if m{(?<=gives=").*?(?=")}' "packages/$pacscript/$pacscript.pacscript")

    if [[ -z $original_old_pkgver ]]; then
      original_old_pkgver=$old_pkgver
    fi

    echo "For ${BPurple}$pacscript${NC},"
    if [[ "$old_pkgver" == "$pkgver" ]]; then
      echo "no pkgver change: ${BYellow}$pkgver${NC}"
    else
      echo "old pkgver: ${BRed}$old_pkgver${NC}"
      echo "new pkgver: ${BGreen}$pkgver${NC}"
    fi
    if [[ "$old_buildver" == "$buildver" ]]; then
      echo "no build pkgver change: ${BYellow}$buildver${NC}"
    else
      echo "old build pkgver: ${BRed}$old_buildver${NC}"
      echo "new build pkgver: ${BGreen}$buildver${NC}"
    fi
    if [[ "$old_gives" == "$gives" ]]; then
      echo "no gives change: ${BYellow}$gives${NC}"
    else
      echo "old gives: ${BRed}$old_gives${NC}"
      echo "new gives: ${BGreen}$gives${NC}"
    fi

    hash_lines=$(grep -o 'hash=".*"' "packages/$pacscript/$pacscript.pacscript" | wc -l)
    if ((hash_lines > 1)); then
      if [[ $package == *"arm64"* ]]; then
        old_hash=$(perl -nle'print $& if m{(?<=hash=").*?(?=")}' "packages/$pacscript/$pacscript.pacscript" | head -1)
        if [[ "$old_hash" == "$hash" ]]; then
          echo "no arm64 hash change: ${BYellow}$hash${NC}"
        else
          echo "old arm64 hash: ${BRed}$old_hash${NC}"
          echo "new arm64 hash: ${BGreen}$hash${NC}"
        fi
      elif [[ $package == *"amd64"* ]]; then
        old_hash=$(perl -nle'print $& if m{(?<=hash=").*?(?=")}' "packages/$pacscript/$pacscript.pacscript" | tail -1)
        if [[ "$old_hash" == "$hash" ]]; then
          echo "no amd64 hash change: ${BYellow}$hash${NC}"
        else
          echo "old amd64 hash: ${BRed}$old_hash${NC}"
          echo "new amd64 hash: ${BGreen}$hash${NC}"
        fi
      fi
    else
      old_hash=$(perl -nle'print $& if m{(?<=hash=").*?(?=")}' "packages/$pacscript/$pacscript.pacscript")
      if [[ "$old_hash" == "$hash" ]]; then
        echo "no hash change: ${BYellow}$hash${NC}"
      else
        echo "old hash: ${BRed}$old_hash${NC}"
        echo "new hash: ${BGreen}$hash${NC}"
      fi
    fi

    if $promptless; then
      answer="1"
    else
      ask "Are you sure you want to proceed with these changes?" N
    fi
    if ((answer == 1)); then
      sed -i "" "s/pkgver=\".*\"/pkgver=\"$pkgver\"/" "packages/$pacscript/$pacscript.pacscript"
      sed -i "" "s/buildver=\".*\"/buildver=\"$buildver\"/" "packages/$pacscript/$pacscript.pacscript"
      sed -i "" "s/gives=\".*\"/gives=\"$gives\"/" "packages/$pacscript/$pacscript.pacscript"
      if ((hash_lines > 1)); then
        if [[ $package == *"arm64"* ]]; then
          awk -v hash="$hash" '/if \[\[ \${CARCH} == "arm64" \]\]; then/{c=1}
                      c&&/hash="/{sub(/hash=".*"/, "hash=\""hash"\""); c=0} 1' "packages/$pacscript/$pacscript.pacscript" >tmpfile && mv tmpfile "packages/$pacscript/$pacscript.pacscript"
        elif [[ $package == *"amd64"* ]]; then
          awk -v hash="$hash" '/else/{c=1}
                      c&&/hash="/{sub(/hash=".*"/, "hash=\""hash"\""); c=0} 1' "packages/$pacscript/$pacscript.pacscript" >tmpfile && mv tmpfile "packages/$pacscript/$pacscript.pacscript"
        fi
      else
        sed -i "" "s/hash=\".*\"/hash=\"$hash\"/" "packages/$pacscript/$pacscript.pacscript"
      fi
    else
      exit 1
    fi
  done

  kernel_script="packages/linux-kernel/linux-kernel.pacscript"
  if $stable; then
    kernel_script="packages/linux-kernel-stable/linux-kernel-stable.pacscript"
  fi

  sed -i "".bak "s/pkgver=\".*\"/pkgver=\"$pkgver\"/" "$kernel_script"
  rm packages/linux-kernel*/*.bak
}

unset stable input_data gitker_remote
promptless=false
newbranch=false

while (($# > 0)); do
  key="$1"
  case $key in
    -S | -s | --stable)
      stable=true
      shift
      ;;
    -M | -m | --mainline)
      stable=false
      shift
      ;;
    -V | -v | --version)
      kerver="${2/\~/-}"
      fetch_kver
      shift
      shift
      ;;
    -Y | -y | --yes)
      promptless=true
      shift
      ;;
    -B | -b | --branch)
      newbranch=true
      shift
      ;;
    -P | -p | --push)
      gitker_remote="$2"
      shift
      shift
      ;;
  esac
done

unset kerselected
if [[ -z ${stable} && -n ${kerver} ]]; then
  if [[ ${kerver} == *"rc"* ]]; then
    echo "${BGreen}INFO${NC}: selecting ${BPurple}mainline${NC}."
    kerselected="main"
    stable=false
    update_ker
  elif [[ $kerver =~ \.0$ ]] || ! [[ $kerver =~ \.[0-9]+\.[0-9]+$ ]]; then
    echo "${BGreen}INFO${NC}: selecting both ${BPurple}mainline${NC} and ${BPurple}stable${NC}."
    kerselected="both"
    stable=true
    update_ker && \
    stable=false
    update_ker
  else
    echo "${BGreen}INFO${NC}: selecting ${BPurple}stable${NC}."
    kerselected="stab"
    stable=true
    update_ker
  fi
else
  if ${stable}; then
    kerselected="stab"
  else
    kerselected="main"
  fi
  update_ker
fi

unset gitker_input
case ${kerselected} in
  both) gitker_input="linux-kernel{-stable}" ;;
  main) gitker_input="linux-kernel" ;;
  stab) gitker_input="linux-kernel-stable" ;;
esac

git add packages/linux*/*pacscript
git commit -m "upd(${gitker_input}): \`$original_old_pkgver\` -> \`$pkgver\`" && \
if ${newbranch} && [[ -n ${gitker_remote} ]]; then
  git push ${gitker_remote} HEAD:refs/heads/${gitker_branch/\~/}
fi
