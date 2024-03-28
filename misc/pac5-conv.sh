#!/usr/bin/env bash

if [[ $(uname -o) == "GNU/Linux" ]]; then
    ggrep() {
        grep "$@"
    }
    sedbackup=""
else
    sedbackup="''"
fi

parse_source_entry() {
    unset source_url dest
    local entry="$1"
    source_url="${entry#*::}"
    dest="${entry%%::*}"
    if [[ $entry != *::* && $entry == *#*=* ]]; then
        dest="${source_url%%#*}"
        dest="${dest##*/}"
    fi
    source_url="${source_url%%#*}"
    if [[ $entry == *::* ]]; then
        dest="${entry%%::*}"
    elif [[ $entry != *#*=* ]]; then
        source_url="$entry"
        dest="${source_url##*/}"
    fi
    if [[ ${dest} == *"?"* ]]; then
        dest="${dest%%\?*}"
    fi
}

update_carch_cases() {
    local file="$1" temp_file="${file}.tmp" in_case_block=false archs=() declare_lines

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ arch=\(\ *\"([^\"]+)\"\ *\)\; ]]; then
            IFS=' ' read -ra archs <<< "${BASH_REMATCH[1]//\"/}"
        fi
        if [[ $line =~ case\ \"\$\{CARCH\}\" ]]; then
            in_case_block=true
            continue
        fi

        if [[ $in_case_block == true ]] && [[ $line =~ esac ]]; then
            in_case_block=false
            echo -e "$declare_lines" >> "$temp_file"
            declare_lines=""
            continue
        fi

        if [[ $in_case_block == true ]]; then
            if [[ $line =~ ([a-z0-9]+)\) ]]; then
                current_arch=${BASH_REMATCH[1]}
            elif [[ $line =~ source\=\(\"([^\"]+)\"\) ]]; then
                declare_lines+="source_${current_arch}=(\"${BASH_REMATCH[1]}\")\n"
            elif [[ $line =~ sha256sums\=\(\"([^\"]+)\"\) ]]; then
                declare_lines+="sha256sums_${current_arch}=(\"${BASH_REMATCH[1]}\")\n"
            fi
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$file"

    mv "$temp_file" "$file"
}

outputted_ifs() {
    for arches in "${arch[@]}"; do
        [[ -n ${hash_values[$arches]} ]] && echo "sha256sums_$arches=(\"${hash_values[$arches]}\")"
        [[ -n ${url_values[$arches]} ]] && echo "source_$arches=(\"${url_values[$arches]}\")"
    done
    for arches in "${arch[@]}"; do
        if [[ -n ${other_vars[$arches]} ]]; then
            [[ $arches == ${arch[0]} ]]  && echo -e "if [[ \${CARCH} == $arches ]]; then" || echo "else"
            echo "${other_vars[$arches]}" | awk 'NR > 1 || NF' | sed -e 's|\&\&|tempAmpersand|g'
            [[ $arches == ${arch[1]} ]] && echo "fi"
        fi
    done
}

process_ifs() {
    local inside_if_block=false current_arch phr=0

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ ^if\ \[\[\ \$\{CARCH\}\ ==\ (.*)\ \]\] ]]; then
            inside_if_block=true
            current_arch="${BASH_REMATCH[1]}"
            current_arch="${current_arch%\"}"
            current_arch="${current_arch#\"}"
            if ! [[ ${other_vars[$current_arch]+_} ]]; then
                other_vars[$current_arch]=""
            fi
            continue
        fi
        if [[ $line == "else" && ${inside_if_block} == true ]]; then
            for arches in "${arch[@]}"; do
                if [[ $arches != "$current_arch" ]]; then
                    current_arch="$arches"
                    break
                fi
            done
            continue
        elif [[ $line == "fi" && ${inside_if_block} == true ]]; then
            inside_if_block=false
            continue
        fi

        if $inside_if_block; then
            if [[ $line =~ sha256sums=\(\"([^\"]*)\"\) ]]; then
                hash_values[$current_arch]="${BASH_REMATCH[1]}"
            elif [[ $line =~ source=\(\"([^\"]*)\"\) ]]; then
                url_values[$current_arch]="${BASH_REMATCH[1]}"
            else
                other_vars[$current_arch]+=$'\n'"${line}"
            fi
            ((phr == 0)) && echo "placeholder${phr}" >> "$temp_file"
            ((phr++))
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$input_file"

    outputted_ifs_escaped=$(printf '%s\n' "$(outputted_ifs)" | sed -e 's/&/\\\&/g' -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g')
    sed -i ${sedbackup} "s|placeholder0|${outputted_ifs_escaped}|g" "$temp_file"
    sed -i ${sedbackup} 's|tempAmpersand|\&\&|g' "$temp_file"
}

update_carch_ifs() {
    input_file="$1"
    temp_file=$(mktemp)
    declare -A hash_values url_values other_vars
    arch_line=$(grep "^arch=" "$input_file")
    eval $arch_line
    process_ifs
    mv "$temp_file" "$input_file"
}

update_carch_stuff() {
    input_carch_file="$1"
    update_carch_cases "$1" && \
    update_carch_ifs "$1"
}

convpy="$(
    cat << EOF
#!/usr/bin/env python3

import re

def subst(file, search_p, replace_p):
    with open(file, 'r') as f:
        contents = f.readlines()

    with open(file, 'w') as f:
        for line in contents:
            line = re.sub(search_p, replace_p, line)
            f.write(line)


def delete_block(file, begin, end):
    with open(file, 'r') as f:
        contents = f.readlines()

    begin_index = None
    end_index = None
    for index, line in enumerate(contents):
        if re.search(begin, line):
            begin_index = index
        if re.search(end, line):
            end_index = index
            break

    if begin_index is not None and end_index is not None:
        del contents[begin_index : end_index + 1]
    with open(file, 'w') as f:
        f.writelines(contents)

def rm_dupe_gives(file):
    with open(file, 'r') as f:
        contents = f.readlines()

    # Track whether a gives= line has been seen
    seen_gives = False
    output_lines = []

    for line in contents:
        if "gives=" in line:
            if not seen_gives:
                # If a gives= line hasn't been seen, add it and mark as seen
                seen_gives = True
                output_lines.append(line)
            # If a gives= line has been seen, skip additional ones
        else:
            # For all other lines, just add them to the output
            output_lines.append(line)

    with open(file, 'w') as f:
        for line in output_lines:
            f.write(line)

def clean_cd(file):
    with open(file, 'r') as f:
        contents = f.readlines()

    optimized_contents = []
    skip_next = False
    for i, line in enumerate(contents[:-1]):
        if skip_next:
            skip_next = False
            continue
        if 'cd "\${_archive}"' in line and 'cd "\${srcdir}"' in contents[i + 1]:
            skip_next = True
            line = '  cd "\${srcdir}"\n'
        optimized_contents.append(line)

    if not skip_next:
        optimized_contents.append(contents[-1])

    with open(file, 'w') as f:
        f.writelines(optimized_contents)

def rm_line(file, pattern):
    with open(file, 'r') as f:
        contents = f.readlines()

    contents = [line for line in contents if line.strip() != pattern]

    with open(file, 'w') as f:
        f.writelines(contents)

with open("packagelist", 'r') as plist:
    for pname in plist:
        p = pname.rstrip()
        ppath = f"packages/{p}/{p}.pacscript"
        if re.search('-git', p):
            delete_block(ppath, r'^pkgver\(\)', '^}')
            subst(ppath, r'url="https(.*)(?<!\.git)"', r'url="git+https\1"')

        subst(ppath, r'^url=(.*)', r'source=(\1)')
        subst(ppath, r'^hash=(.*)', r'sha256sums=(\1)')
        subst(ppath, r'\ \ url=(.*)', r'  source=(\1)')
        subst(ppath, r'\ \ hash=(.*)', r'  sha256sums=(\1)')
        subst(ppath, r'^maintainer=(.*)', r'maintainer=(\1)')
        subst(ppath, r'^replace=\((.*)\)', r'replaces=(\1)')
        subst(ppath, r'^homepage="(.*)"', r'url="\1"')
        subst(ppath, r'SRCDIR', r'srcdir')
        subst(ppath, r'pkgname', r'gives')
        subst(ppath, r'^name="(.*)"', r'pkgname="\1"')
        subst(ppath, r'\\$\{name\}', r'\${pkgname}')
        subst(ppath, r'prepare\(\) {', r'prepare() {\n  cd "\${_archive}"')
        subst(ppath, r'build\(\) {', r'build() {\n  cd "\${_archive}"')
        subst(ppath, r'package\(\) {', r'package() {\n  cd "\${_archive}"')
        subst(ppath, r'cd \.\.', r'cd "\${srcdir}"')
        rm_line(ppath, 'gives="\${gives}"')
        rm_dupe_gives(ppath)
        clean_cd(ppath)
EOF
)"
echo "${convpy}" | tee conv.py >> /dev/null

update_wget_stuff() {
    unset packageArray
    while IFS= read -r line; do
        if [[ ! " ${packageArray[*]} " =~ " ${line} " ]]; then
            packageArray+=("$line")
        fi
    done < <(grep " wget\| curl" packages/*/*pacscript | grep -v 'O "${i}"' | grep -v '\${s}' | grep -v 'skiaurl' | grep -v 'pkgdir' | grep -v '\-P' | grep -v '\\' | awk '{print $1}' | sed -e 's/packages\///' -e 's/\/[^\/]*.pacscript://')

    for pkg in "${packageArray[@]}"; do
        unset destArray
        unset urlArray
        unset desturlArray
        unset fulldestArray
        unset linesArray

        while IFS= read -r line; do
            if [[ ! " ${destArray[*]} " =~ " ${line} " ]]; then
                destArray+=("$line")
            fi
        done < <(ggrep -Po "(wget|curl).*?(-O|-qO|-o)\s+\K(\"[^\"]*\"|\S+)" packages/${pkg}/${pkg}.pacscript | grep -v '\${s}' | sed -e 's/\"//g' -e "s/\'//g")

        while IFS= read -r line; do
            if [[ ! " ${desturlArray[*]} " =~ " ${line} " ]]; then
                desturlArray+=("$line")
            fi
        done < <(grep -e " wget\| curl" packages/${pkg}/${pkg}.pacscript | grep -e ' -O\| -o\| -qO' | grep -v '\${s}' | sed -e 's/sudo wget//' -e 's/sudo curl//' -e 's/wget//' -e 's/curl//' -e 's/-qO//' -e 's/-q//' -e 's/-O//' -e 's/-L#//' -e 's/-sO//' -e 's/-o//' -e 's/\"//g' -e "s/\'//g" | awk '{$1=$1};1')

        while IFS= read -r line; do
            if [[ ! " ${urlArray[*]} " =~ " ${line} " ]]; then
                line=${line/\'/}
                line=${line/\'/}
                urlArray+=("$line")
            fi
        done < <(grep -e " wget\| curl" packages/${pkg}/${pkg}.pacscript | grep -v ' -O\| -o\| -qO' | grep -v '\${s}' | sed -e 's/sudo wget//' -e 's/sudo curl//' -e 's/wget//' -e 's/curl//' -e 's/-qO//' -e 's/-q//' -e 's/-O//' -e 's/-L#//' -e 's/-sO//' -e 's/-o//' -e 's/\"//g' -e "s/\'//g" | awk '{$1=$1};1')

        while IFS= read -r line; do
            if [[ ! " ${linesArray[*]} " =~ " ${line} " ]]; then
                linesArray+=("$line")
            fi
        done < <(grep -e " wget\| curl" packages/${pkg}/${pkg}.pacscript | grep -v '\${s}' | grep -v 'skiaurl' | grep -v 'pkgdir' | grep -v '\-P' | grep -v '\\')

        for url in "${!urlArray[@]}"; do
            parse_source_entry "${urlArray[$url]}"
            fulldestArray+=("$dest")
        done
        for first in "${!desturlArray[@]}"; do
            for second in "${!destArray[@]}"; do
                if [[ " ${desturlArray[$first]} " =~ " ${destArray[$second]} " ]]; then
                    desturlArray[$first]="${desturlArray[$first]//${destArray[$second]} /}"
                    desturlArray[$first]="${desturlArray[$first]// ${destArray[$second]}/}"
                    desturlArray[$first]="${desturlArray[$first]/ /}"
                fi
            done
        done
        for i in "${!destArray[@]}"; do
            destArray[$i]="${destArray[$i]/\.\//}"
            mapfile -t -O"${#fulldestArray[@]}" fulldestArray <<< "${destArray[$i]}"
            mapfile -t -O"${#urlArray[@]}" urlArray <<< "${desturlArray[$i]}"
        done
        for tworl in "${!urlArray[@]}"; do
            if [[ -z "${fulldestArray[$tworl]}" ]]; then
                parse_source_entry "${urlArray[$tworl]}"
                fulldestArray[$tworl]="$dest"
            fi
        done

        source_line=$(grep "^source=" "packages/${pkg}/${pkg}.pacscript")
        sourcelink="${source_line/source\=\(/}"
        sourcelink="${sourcelink/\)/}"
        new_source() {
            new_source_line=("source=(")
            new_source_line+=("${sourcelink}")
            for out in "${!urlArray[@]}"; do
                new_source_line+=("\"${fulldestArray[$out]}::${urlArray[$out]}\"")
            done
            for so in "${new_source_line[@]}"; do
                if [[ ${so} == "source=(" ]]; then
                    echo "${so}\\"
                else
                    echo "  ${so}\\"
                fi
            done
            echo ")"
        }
        nsource="$(new_source)"
        sed -i ${sedbackup} "s|${source_line}|${nsource}|g" packages/${pkg}/${pkg}.pacscript
        new_arch_line=$(grep "^arch=" "packages/${pkg}/${pkg}.pacscript")
        eval $new_arch_line
        unset shaentries
        if grep "^sha256sums=" "packages/${pkg}/${pkg}.pacscript" >> /dev/null; then
            shaentries+=("sha256sums")
        fi
        for ar in ${!arch[@]}; do
            if grep "^sha256sums_${arch[$ar]}=" "packages/${pkg}/${pkg}.pacscript" >> /dev/null; then
                shaentries+=("sha256sums_${arch[$ar]}")
            fi
        done
        new_sha() {
            shamatch="${sha_line/${1}\=\(/}"
            shamatch="${shamatch/\)/}"
            new_sha_line=("${1}=(")
            if [[ -n ${shamatch} ]]; then
                new_sha_line+=("${shamatch}")
            fi
            for out in "${!urlArray[@]}"; do
                new_sha_line+=("\"SKIP\"")
            done
            for sa in "${new_sha_line[@]}"; do
                if [[ ${sa} == "${1}=(" ]]; then
                    echo "${sa}\\"
                else
                    echo "  ${sa}\\"
                fi
            done
            echo ")"
        }
        for shaent in "${shaentries[@]}"; do
            sha_line=$(grep "^${shaent}=" "packages/${pkg}/${pkg}.pacscript")
            if [[ -n ${sha_line} ]]; then
                nsha="$(new_sha ${shaent})"
                sed -i ${sedbackup} "s|${sha_line}|${nsha}|g" packages/${pkg}/${pkg}.pacscript
            fi
        done
        if [[ -z ${shaentries[*]} ]]; then
            sha_line="sha256sums=(\"SKIP\")"
            nsha="$(new_sha sha256sums)"
            echo "" | tee -a packages/${pkg}/${pkg}.pacscript > /dev/null
            echo -e "${nsha}" | sed -e 's/\\//g' |  tee -a packages/${pkg}/${pkg}.pacscript > /dev/null
        fi
        for lin in "${!linesArray[@]}"; do
            escapedPattern=$(printf '%s\n' "${linesArray[$lin]}" | sed 's:[][\/.^$*]:\\&:g')
            sed -i ${sedbackup} "/${escapedPattern}/d" packages/${pkg}/${pkg}.pacscript
        done
        for ful in "${!fulldestArray[@]}"; do
            sed -i ${sedbackup} "s/ ${fulldestArray[$ful]}/ \${srcdir}\/${fulldestArray[$ful]}/g" packages/${pkg}/${pkg}.pacscript
            sed -i ${sedbackup} "s/ \"${fulldestArray[$ful]}\"/ \"\${srcdir}\/${fulldestArray[$ful]}\"/g" packages/${pkg}/${pkg}.pacscript
        done
    done
}

python3 conv.py
rm conv.py

files=($(cat packagelist))

for file in "${files[@]}"; do
    update_carch_stuff "packages/$file/$file.pacscript"
done && \
update_wget_stuff
