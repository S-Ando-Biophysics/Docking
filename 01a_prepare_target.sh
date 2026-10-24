#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"


# ============================================================
# Settings
# ============================================================

INPUT_DIR="00_INPUT"
OUTDIR="01_PREPARE"

INPUT_COPY="$OUTDIR/target_input.pdb"
AMBER_MOL2="$OUTDIR/target_charged.mol2"
DOCK_MOL2="$OUTDIR/target_DOCK.mol2"

LEAP_IN="$OUTDIR/leap.in"
LEAP_OUT="$OUTDIR/leap.out"

SUMMARY="$OUTDIR/target_prepare_summary.txt"

mkdir -p "$OUTDIR"


# ============================================================
# Dependency check
# ============================================================

for CMD in tleap python3; do

    if ! command -v "$CMD" >/dev/null 2>&1; then

        echo
        echo "ERROR: $CMD was not found."
        echo

        exit 1

    fi

done


# ============================================================
# Check input directory
# ============================================================

if [[ ! -d "$INPUT_DIR" ]]; then

    echo
    echo "ERROR: Input directory was not found:"
    echo
    echo "  $INPUT_DIR"
    echo

    exit 1

fi


# ============================================================
# Find candidate PDB files
# ============================================================

mapfile -t TARGET_FILES < <(
    find "$INPUT_DIR" \
        -maxdepth 1 \
        -type f \
        -iname "*.pdb" \
        | sort
)


if [[ "${#TARGET_FILES[@]}" -eq 0 ]]; then

    echo
    echo "ERROR: No PDB files were found in:"
    echo
    echo "  $INPUT_DIR"
    echo

    exit 1

fi


# ============================================================
# Select target
# ============================================================

echo
echo "============================================================"
echo " DOCK6 nucleic-acid target preparation"
echo "============================================================"
echo

echo "Available PDB structures in $INPUT_DIR:"
echo


for i in "${!TARGET_FILES[@]}"; do

    printf \
        "  [%d] %s\n" \
        "$((i + 1))" \
        "$(basename "${TARGET_FILES[$i]}")"

done


echo


while true; do

    read -r -p \
        "Select nucleic-acid target [1-${#TARGET_FILES[@]}]: " \
        SELECTION


    if [[ "$SELECTION" =~ ^[0-9]+$ ]] &&
       (( SELECTION >= 1 )) &&
       (( SELECTION <= ${#TARGET_FILES[@]} )); then

        break

    fi


    echo "Invalid selection."

done


INPUT="${TARGET_FILES[$((SELECTION - 1))]}"


echo
echo "Selected target:"
echo
echo "  $INPUT"
echo


# ============================================================
# Copy original target
#
# The original PDB is assumed to contain NO hydrogens.
# This copy is also used directly for Chimera DMS generation.
# ============================================================

cp \
    "$INPUT" \
    "$INPUT_COPY"


if [[ ! -s "$INPUT_COPY" ]]; then

    echo
    echo "ERROR: Failed to copy target PDB."
    echo

    exit 1

fi


# ============================================================
# Inspect input
# ============================================================

PDB_INFO="$(
python3 - "$INPUT_COPY" <<'PY'

from pathlib import Path
from collections import OrderedDict
import sys


path = Path(sys.argv[1])


atoms = 0
hydrogens = 0

chains = OrderedDict()
residue_names = OrderedDict()
hetatm_residues = OrderedDict()

waters = set()
ions = []


ION_ELEMENTS = {
    "K",
    "NA",
    "MG",
    "CA",
    "ZN",
    "MN",
    "FE",
    "CU",
    "CO",
    "NI",
}


def element_from_pdb(line, atom_name):

    element = line[76:78].strip().upper()

    if element:
        return element

    name = atom_name.upper()

    while name and name[0].isdigit():
        name = name[1:]

    two = name[:2]

    if two in {
        "MG",
        "CA",
        "ZN",
        "MN",
        "FE",
        "CU",
        "CO",
        "NI",
        "NA",
    }:
        return two

    if name.startswith("K"):
        return "K"

    return name[:1]


for line in path.read_text().splitlines():

    if not (
        line.startswith("ATOM")
        or line.startswith("HETATM")
    ):
        continue


    atoms += 1


    atom_name = line[12:16].strip()
    resname = line[17:20].strip()
    chain = line[21:22].strip() or "_"
    resid = line[22:26].strip()
    icode = line[26:27].strip()

    resid_full = resid + icode


    element = element_from_pdb(
        line,
        atom_name,
    )


    chains.setdefault(
        chain,
        None,
    )


    residue_names.setdefault(
        resname,
        None,
    )


    if element == "H":
        hydrogens += 1


    if line.startswith("HETATM"):

        hetatm_residues.setdefault(
            (
                resname,
                chain,
                resid_full,
            ),
            None,
        )


        if resname.upper() in {
            "HOH",
            "WAT",
            "H2O",
        }:

            waters.add(
                (
                    chain,
                    resid_full,
                )
            )


    if element in ION_ELEMENTS:

        ions.append(
            (
                element,
                atom_name,
                resname,
                chain,
                resid_full,
            )
        )


print(
    f"ATOMS={atoms}"
)

print(
    f"HYDROGENS={hydrogens}"
)

print(
    f"WATERS={len(waters)}"
)

print(
    f"IONS={len(ions)}"
)


for chain in chains:

    print(
        f"CHAIN={chain}"
    )


for resname in residue_names:

    print(
        f"RESNAME={resname}"
    )


for item in hetatm_residues:

    print(
        "HETATM="
        + ":".join(item)
    )


for ion in ions:

    print(
        "ION="
        + "|".join(ion)
    )

PY
)"


ORIGINAL_ATOMS="$(
    printf '%s\n' "$PDB_INFO" \
        | awk -F= '$1=="ATOMS"{print $2}'
)"


H_COUNT="$(
    printf '%s\n' "$PDB_INFO" \
        | awk -F= '$1=="HYDROGENS"{print $2}'
)"


WATER_COUNT="$(
    printf '%s\n' "$PDB_INFO" \
        | awk -F= '$1=="WATERS"{print $2}'
)"


ION_COUNT_INPUT="$(
    printf '%s\n' "$PDB_INFO" \
        | awk -F= '$1=="IONS"{print $2}'
)"


CHAINS="$(
    printf '%s\n' "$PDB_INFO" \
        | awk -F= '$1=="CHAIN"{print $2}'
)"


RESNAMES="$(
    printf '%s\n' "$PDB_INFO" \
        | awk -F= '$1=="RESNAME"{print $2}'
)"


HETATM_LIST="$(
    printf '%s\n' "$PDB_INFO" \
        | awk -F= '$1=="HETATM"{print $2}'
)"


ION_LIST="$(
    printf '%s\n' "$PDB_INFO" \
        | awk -F= '$1=="ION"{print $2}'
)"


if [[ "$ORIGINAL_ATOMS" -eq 0 ]]; then

    echo
    echo "ERROR: No ATOM/HETATM records were found."
    echo

    exit 1

fi


# ============================================================
# Enforce current workflow assumption:
# input receptor should already be hydrogen-free
# ============================================================

if [[ "$H_COUNT" -ne 0 ]]; then

    echo
    echo "============================================================"
    echo " ERROR"
    echo "============================================================"
    echo
    echo "Hydrogen atoms were detected in the input PDB:"
    echo
    echo "  $H_COUNT"
    echo
    echo "This workflow assumes that the input target PDB"
    echo "is already hydrogen-free."
    echo
    echo "Please use a hydrogen-free target PDB."
    echo

    exit 1

fi


# ============================================================
# Show input information
# ============================================================

echo "------------------------------------------------------------"
echo " Input structure"
echo "------------------------------------------------------------"
echo

echo "Atoms:"
echo
echo "  $ORIGINAL_ATOMS"
echo

echo "Hydrogens:"
echo
echo "  $H_COUNT"
echo

echo "Chains:"
echo


while IFS= read -r CHAIN; do

    [[ -z "$CHAIN" ]] && continue

    if [[ "$CHAIN" == "_" ]]; then
        echo "  (blank chain ID)"
    else
        echo "  $CHAIN"
    fi

done <<< "$CHAINS"


echo
echo "Residue names:"
echo


while IFS= read -r RESNAME; do

    [[ -z "$RESNAME" ]] && continue

    echo "  $RESNAME"

done <<< "$RESNAMES"


echo
echo "Water molecules:"
echo
echo "  $WATER_COUNT"
echo

echo "Detected ions:"
echo
echo "  $ION_COUNT_INPUT"
echo


if [[ -n "$ION_LIST" ]]; then

    echo "Ion records:"
    echo

    while IFS= read -r LINE; do
        echo "  $LINE"
    done <<< "$ION_LIST"

    echo

fi


if [[ -n "$HETATM_LIST" ]]; then

    echo "HETATM residues:"
    echo

    while IFS= read -r LINE; do
        echo "  $LINE"
    done <<< "$HETATM_LIST"

    echo

fi


# ============================================================
# Select Amber nucleic-acid force field
# ============================================================

echo "============================================================"
echo " Amber nucleic-acid force field"
echo "============================================================"
echo

echo "  [1] OL3"
echo
echo "  [2] OL24"
echo


while true; do

    read -r -p \
        "Select force field [1-2]: " \
        FF_CHOICE


    case "$FF_CHOICE" in

        1)

            FORCE_FIELD_NAME="OL3"
            LEAPRC="leaprc.RNA.OL3"
            break
            ;;

        2)

            FORCE_FIELD_NAME="OL24"
            LEAPRC="leaprc.DNA.OL24"
            break
            ;;

        *)

            echo "Invalid selection."
            ;;
    esac

done


echo
echo "Selected force field:"
echo
echo "  $FORCE_FIELD_NAME"
echo

echo "Amber preset:"
echo
echo "  $LEAPRC"
echo


# ============================================================
# Important note for residue naming
# ============================================================

echo "------------------------------------------------------------"
echo " Residue-name check"
echo "------------------------------------------------------------"
echo

echo "LEaP must recognize the nucleotide residue names in the PDB."
echo
echo "Detected residue names:"
echo

while IFS= read -r RESNAME; do

    [[ -z "$RESNAME" ]] && continue
    echo "  $RESNAME"

done <<< "$RESNAMES"

echo


# ============================================================
# Generate tleap input
#
# Amber is used here ONLY to assign:
#   - nucleic-acid atom types
#   - partial atomic charges
#
# for the receptor MOL2 used by DOCK6 GRID.
#
# No MD topology or restart files are generated.
# The original coordinates are retained as the input geometry.
# ============================================================

cat > "$LEAP_IN" <<EOF
source ${LEAPRC}
source leaprc.water.tip3p

target = loadPdb target_input.pdb

check target
charge target

saveMol2 target target_charged.mol2 0

quit
EOF


# ============================================================
# Remove old generated files
# ============================================================

rm -f \
    "$AMBER_MOL2" \
    "$DOCK_MOL2" \
    "$LEAP_OUT" \
    "$SUMMARY"


# ============================================================
# Run tleap
# ============================================================

echo
echo "============================================================"
echo " Running tleap"
echo "============================================================"
echo

echo "Purpose:"
echo
echo "  Assign Amber atom types and partial charges for DOCK6 GRID."
echo


(
    cd "$OUTDIR"

    tleap \
        -f leap.in \
        2>&1 \
        | tee leap.out
)


# ============================================================
# Validate tleap output
# ============================================================

if [[ ! -s "$AMBER_MOL2" ]]; then

    echo
    echo "ERROR:"
    echo "tleap did not generate:"
    echo
    echo "  $AMBER_MOL2"
    echo
    echo "Check:"
    echo
    echo "  $LEAP_OUT"
    echo

    exit 1

fi


# ============================================================
# Detect LEaP problems
# ============================================================

echo
echo "------------------------------------------------------------"
echo " tleap summary"
echo "------------------------------------------------------------"
echo


grep -Ei \
    'Errors|Warnings|Notes|Total .*charge|Unit is OK|Unknown|FATAL' \
    "$LEAP_OUT" \
    || true


echo


if grep -Eqi \
    'FATAL|Unknown residue|Could not find atom type|Errors *= *[1-9]' \
    "$LEAP_OUT"
then

    echo "============================================================"
    echo " ERROR"
    echo "============================================================"
    echo
    echo "Potential tleap errors were detected."
    echo
    echo "Do not continue to GRID until the residue/atom"
    echo "recognition problem has been resolved."
    echo
    echo "Check:"
    echo
    echo "  $LEAP_OUT"
    echo

    exit 1

fi


# ============================================================
# Correct MOL2 SET-count compatibility
# ============================================================

echo
echo "============================================================"
echo " Checking receptor MOL2 compatibility"
echo "============================================================"
echo


python3 - \
    "$AMBER_MOL2" \
    "$DOCK_MOL2" <<'PY'

from pathlib import Path
import sys


src = Path(sys.argv[1])
dst = Path(sys.argv[2])


lines = src.read_text().splitlines()


try:

    molecule_index = next(
        i
        for i, line in enumerate(lines)
        if line.strip() == "@<TRIPOS>MOLECULE"
    )

except StopIteration:

    raise SystemExit(
        "ERROR: @<TRIPOS>MOLECULE was not found."
    )


counts_index = molecule_index + 2


if counts_index >= len(lines):

    raise SystemExit(
        "ERROR: MOL2 counts line was not found."
    )


fields = lines[counts_index].split()


if len(fields) < 5:

    raise SystemExit(
        "ERROR: Invalid MOL2 counts line:\n"
        + lines[counts_index]
    )


has_set = any(
    line.strip() == "@<TRIPOS>SET"
    for line in lines
)


print(
    "Counts line before:"
)

print(
    " ",
    lines[counts_index],
)

print()

print(
    "@<TRIPOS>SET:",
    "present"
    if has_set
    else "absent",
)


if not has_set:

    old = fields[4]

    fields[4] = "0"

    lines[counts_index] = (
        "  "
        + "   ".join(fields)
    )

    print()

    print(
        f"SET count: {old} -> 0"
    )

else:

    print()

    print(
        "SET section exists; count not modified."
    )


dst.write_text(
    "\n".join(lines)
    + "\n"
)


print()

print(
    "Counts line after:"
)

print(
    " ",
    lines[counts_index],
)

PY


if [[ ! -s "$DOCK_MOL2" ]]; then

    echo
    echo "ERROR: target_DOCK.mol2 was not generated."
    echo

    exit 1

fi


# ============================================================
# Validate final DOCK receptor MOL2
# ============================================================

VALIDATION="$(
python3 - "$DOCK_MOL2" <<'PY'

from pathlib import Path
import sys


path = Path(sys.argv[1])

lines = path.read_text().splitlines()


in_atom = False

natoms = 0
charge = 0.0

bad_atom_lines = 0
bad_charge_lines = 0

atom_types = {}
ions = []


ION_TYPES = {
    "K",
    "NA",
    "MG",
    "CA",
    "ZN",
    "MN",
    "FE",
    "CU",
    "CO",
    "NI",
}


for line in lines:

    stripped = line.strip()


    if stripped == "@<TRIPOS>ATOM":

        in_atom = True
        continue


    if stripped.startswith("@<TRIPOS>"):

        in_atom = False
        continue


    if not in_atom or not stripped:
        continue


    f = line.split()


    if len(f) < 9:

        bad_atom_lines += 1
        continue


    natoms += 1


    atom_type = f[5]


    atom_types[atom_type] = (
        atom_types.get(
            atom_type,
            0,
        )
        + 1
    )


    try:

        charge += float(
            f[8]
        )

    except ValueError:

        bad_charge_lines += 1


    if atom_type.upper() in ION_TYPES:

        ions.append(
            (
                f[0],
                f[1],
                f[5],
                f[8],
            )
        )


print(
    f"ATOMS={natoms}"
)

print(
    f"CHARGE={charge:.6f}"
)

print(
    f"BAD_ATOMS={bad_atom_lines}"
)

print(
    f"BAD_CHARGES={bad_charge_lines}"
)

print(
    f"IONS={len(ions)}"
)


for atom_type in sorted(atom_types):

    print(
        f"TYPE={atom_type}|"
        f"{atom_types[atom_type]}"
    )


for ion in ions:

    print(
        "ION="
        + "|".join(ion)
    )

PY
)"


ATOM_COUNT="$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="ATOMS"{print $2}'
)"


TOTAL_CHARGE="$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="CHARGE"{print $2}'
)"


BAD_ATOMS="$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="BAD_ATOMS"{print $2}'
)"


BAD_CHARGES="$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="BAD_CHARGES"{print $2}'
)"


ION_COUNT_AFTER="$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="IONS"{print $2}'
)"


ATOM_TYPES="$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="TYPE"{print $2}'
)"


ION_LINES="$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="ION"{print $2}'
)"


if [[ "$ATOM_COUNT" -eq 0 ]]; then

    echo
    echo "ERROR: No receptor atoms were found in target_DOCK.mol2."
    echo

    exit 1

fi


if [[ "$BAD_ATOMS" -ne 0 ]]; then

    echo
    echo "ERROR:"
    echo "Malformed receptor MOL2 atom lines were detected:"
    echo
    echo "  $BAD_ATOMS"
    echo

    exit 1

fi


if [[ "$BAD_CHARGES" -ne 0 ]]; then

    echo
    echo "ERROR:"
    echo "Invalid receptor partial charges were detected:"
    echo
    echo "  $BAD_CHARGES"
    echo

    exit 1

fi


# ============================================================
# MOL2 counts line
# ============================================================

MOL2_COUNTS="$(
python3 - "$DOCK_MOL2" <<'PY'

from pathlib import Path
import sys


lines = Path(
    sys.argv[1]
).read_text().splitlines()


for i, line in enumerate(lines):

    if line.strip() == "@<TRIPOS>MOLECULE":

        if i + 2 < len(lines):

            print(
                lines[i + 2]
            )

        break

PY
)"


# ============================================================
# Summary
# ============================================================

{
    echo "============================================================"
    echo " DOCK6 nucleic-acid target preparation summary"
    echo "============================================================"
    echo

    echo "[Input]"
    echo "Selected target        : $INPUT"
    echo "Copied input           : $INPUT_COPY"
    echo "Force field            : $FORCE_FIELD_NAME"
    echo "Input hydrogens        : $H_COUNT"
    echo

    echo "[Amber]"
    echo "Purpose                : atom types + partial charges"
    echo "LEaP preset            : $LEAPRC"
    echo "MD topology generated  : NO"
    echo "Restart generated      : NO"
    echo

    echo "[Input structure]"
    echo "Atoms                  : $ORIGINAL_ATOMS"
    echo "Water molecules        : $WATER_COUNT"
    echo "Detected ions          : $ION_COUNT_INPUT"
    echo

    echo "[DOCK6 receptor]"
    echo "Atoms                  : $ATOM_COUNT"
    echo "Total partial charge   : $TOTAL_CHARGE"
    echo "Detected ions          : $ION_COUNT_AFTER"
    echo "MOL2 counts line       : $MOL2_COUNTS"
    echo

    echo "[Output]"
    echo "Original target copy   : $INPUT_COPY"
    echo "Amber MOL2             : $AMBER_MOL2"
    echo "DOCK6 receptor MOL2    : $DOCK_MOL2"
    echo "LEaP input             : $LEAP_IN"
    echo "LEaP log               : $LEAP_OUT"
    echo

    echo "[Chimera]"
    echo "Open this PDB          : $INPUT_COPY"
    echo "Write DMS into         : $INPUT_DIR/"
    echo "Save surface normals   : YES"

} > "$SUMMARY"


# ============================================================
# Final report
# ============================================================

echo
echo "============================================================"
echo " Target preparation completed"
echo "============================================================"
echo

echo "Force field:"
echo
echo "  $FORCE_FIELD_NAME"
echo

echo "Amber preset:"
echo
echo "  $LEAPRC"
echo

echo "Input hydrogens:"
echo
echo "  $H_COUNT"
echo

echo "DOCK6 receptor:"
echo
echo "  $DOCK_MOL2"
echo

echo "Atoms:"
echo
echo "  $ATOM_COUNT"
echo

echo "Total partial charge:"
echo
echo "  $TOTAL_CHARGE"
echo

echo "Generated files:"
echo
echo "  $INPUT_COPY"
echo "  $AMBER_MOL2"
echo "  $DOCK_MOL2"
echo "  $LEAP_IN"
echo "  $LEAP_OUT"
echo "  $SUMMARY"
echo


# ============================================================
# Required Chimera step
# ============================================================

echo "============================================================"
echo " REQUIRED: Chimera DMS generation"
echo "============================================================"
echo

echo "Use the ORIGINAL hydrogen-free coordinates:"
echo
echo "  $INPUT_COPY"
echo

echo "In UCSF Chimera:"
echo
echo "  1. Open $INPUT_COPY"
echo "  2. Generate the molecular surface"
echo "  3. Write DMS"
echo "  4. Save surface normals = ON"
echo "  5. Save the *.dms / *.ms file into:"
echo
echo "       $INPUT_DIR/"
echo

echo "Then run:"
echo
echo "  bash 02a_generate_spheres.sh"
echo
