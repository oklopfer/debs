#!/usr/bin/env bash

srcinfo() {
    local CARCH='${CARCH}' DISTRO='${DISTRO}' src sum vars a_sum var ar car \
        known_hashsums_src=("b2" "sha512" "sha384" "sha256" "sha224" "sha1" "md5") \
        known_archs_src=("amd64" "arm64" "armel" "armhf" "i386" "mips64el" "ppc64el" "riscv64" "s390x") \
        allvars=("pkgname" "gives" "pkgver" "pkgrel" "epoch" "pkgdesc" "url" "priority") \
        allars=("source" "depends" "makedepends" "checkdepends" "optdepends" "pacdeps" "conflicts" "breaks" \
        "replaces" "provides" "arch" "incompatible" "compatible" "backup" "mask" "noextract" "nosubmodules" "license")
    source ${1}
    for src in "${known_archs_src[@]}"; do
        for vars in {source,depends,makedepends,optdepends,pacdeps,checkdepends,provides,conflicts,breaks,replaces}; do
            allars+=("${vars}_${src}")
        done
        allvars+=("gives_${src}")
    done
    for sum in "${known_hashsums_src[@]}"; do
        allars+=("${sum}sums")
        for a_sum in "${known_archs_src[@]}"; do
            allars+=("${sum}sums_${a_sum}")
        done
    done
    for var in "${allvars[@]}"; do
        [[ -n ${!var} ]] && echo "${var}=\"${!var}\""
    done
    for ar in "${allars[@]}"; do
        [[ -n ${!ar} ]] && \
        declare -p ${ar} | sed -e 's|\\||g'
    done
    unset "${allars[@]}" "${allvars[@]}"
}

mapfile -t packagelist < packagelist
for package in "${packagelist[@]}"; do
    srcinfo packages/${package}/${package}.pacscript | tee packages/${package}/.SRCINFO > /dev/null
done
unset packagelist
