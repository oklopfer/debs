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

ask "Are you updating stable kernel packages?" N
if ((answer == 0)); then
    stable="N"
else
    stable="Y"
fi

echo "Paste file inputs (${BPurple}type EOF when done${NC}):"
input_data=()
while IFS= read -r line; do
  [[ $line == "EOF" ]] && break
  input_data+=("$line")
done

parse_filename() {
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

  [[ $stable == "y" || $stable == "Y" ]] && name+="-stable"
  name+="-deb"

  echo $name
}

for line in "${input_data[@]}"; do
  IFS=' ' read -r -a arr <<<"$line"
  hash=${arr[0]}
  package=${arr[1]}
  if [[ $stable == "y" || $stable == "Y" ]]; then
    buildver=$(echo "$package" | perl -nle'print $& if m{([0-9]+\.[0-9]+(-rc[0-9]+)?\.[0-9]+-[0-9]+\.?[0-9]*\.?[0-9]*\.[0-9]*)}')
  else
    if [[ $package == *"rc"* ]]; then
      buildver=$(echo "$package" | perl -nle'print $& if m{([0-9]+\.[0-9]+\.?[0-9]*-?[0-9]*rc?[0-9]*\.[0-9]+)}')
    else
      buildver=$(echo "$package" | perl -nle'print $& if m{([0-9]+\.[0-9]+(-rc[0-9]+)?\.[0-9]+-[0-9]+\.?[0-9]*\.?[0-9]*\.[0-9]*)}')
    fi
  fi
  gives=$(echo "$package" | perl -nle'print $& if m{(linux-.+?)_}')
  gives=${gives%_} # Remove trailing underscore
  if [[ $stable == "y" || $stable == "Y" ]]; then
    pkgver=$(echo "$package" | perl -nle'print $& if m{([0-9]+\.[0-9]+\.[0-9]+)}')
    pkgver=${pkgver//.0/} # Remove '.0' from pkgver
  else
    pkgver=$(echo "$gives" | perl -nle'print $& if m{([0-9]+\.[0-9]+)}') # Get the first set of numbers
    rc_number="$(echo "$package" | perl -nle'print $& if m{(rc[0-9]+)}')" # Get the 'rc' string
    if ! [[ "${rc_number}" == "" ]]; then
      rc_number="~${rc_number}"
    fi
    pkgver+="${rc_number}" # Append "-rc#" to pkgver
    pkgver=${pkgver//.0/} # Remove '.0' from pkgver
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

  echo -n "Are you sure you want to proceed with these changes? [${BGreen}y${NC}/${BRed}N${NC}] "

  read -r response
  if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
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
  fi
  echo
done

kernel_script="packages/linux-kernel/linux-kernel.pacscript"
[[ $stable == "y" || $stable == "Y" ]] && kernel_script="packages/linux-kernel-stable/linux-kernel-stable.pacscript"

sed -i "".bak "s/pkgver=\".*\"/pkgver=\"$pkgver\"/" "$kernel_script"
rm packages/*/*bak

kerstable=""
[[ $stable == "y" || $stable == "Y" ]] && kerstable="-stable"

git add packages/*/*pacscript
git commit -m "upd(linux-kernel${kerstable}): \`$original_old_pkgver\` -> \`$pkgver\`"
