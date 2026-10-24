#!/usr/bin/env bash

set -euo pipefail


# ------------------------------------------------------------
# Move to project directory
# ------------------------------------------------------------

cd "$(dirname "$0")"


# ------------------------------------------------------------
# Settings
# ------------------------------------------------------------

INPUT_DIR="00_INPUT"
OUTDIR="01_PREPARE"

OUTPUT="$OUTDIR/LIG_DOCK.mol2"
SUMMARY="$OUTDIR/ligand_prepare_summary.txt"

mkdir -p "$OUTDIR"


# ------------------------------------------------------------
# Check dependencies
# ------------------------------------------------------------

if ! command -v python3 >/dev/null 2>&1; then

    echo
    echo "ERROR: python3 was not found."
    echo

    exit 1

fi


# ------------------------------------------------------------
# Find candidate MOL2 files
# ------------------------------------------------------------

mapfile -t LIGAND_FILES < <(
    find "$INPUT_DIR" \
        -maxdepth 1 \
        -type f \
        -iname "*.mol2" \
        | sort
)


if [[ "${#LIGAND_FILES[@]}" -eq 0 ]]; then

    echo
    echo "ERROR: No MOL2 ligand files were found in:"
    echo
    echo "  $INPUT_DIR"
    echo

    exit 1

fi


# ------------------------------------------------------------
# Interactive ligand selection
# ------------------------------------------------------------

echo
echo "============================================================"
echo " DOCK6 ligand preparation"
echo "============================================================"
echo

echo "Available MOL2 files in $INPUT_DIR:"
echo


for i in "${!LIGAND_FILES[@]}"; do

    printf "  [%d] %s\n" \
        "$((i + 1))" \
        "$(basename "${LIGAND_FILES[$i]}")"

done


echo


while true; do

    read -r -p \
        "Select ligand [1-${#LIGAND_FILES[@]}]: " \
        SELECTION

    if [[ "$SELECTION" =~ ^[0-9]+$ ]] &&
       (( SELECTION >= 1 && SELECTION <= ${#LIGAND_FILES[@]} )); then

        break

    fi

    echo "Invalid selection."

done


INPUT="${LIGAND_FILES[$((SELECTION - 1))]}"
INPUT_NAME="$(basename "$INPUT")"

INPUT_COPY="$OUTDIR/LIG_input.mol2"


echo
echo "Selected ligand:"
echo
echo "  $INPUT"
echo


# ------------------------------------------------------------
# Copy original ligand
# ------------------------------------------------------------

cp "$INPUT" "$INPUT_COPY"


if [[ ! -s "$INPUT_COPY" ]]; then

    echo
    echo "ERROR: Failed to copy ligand."
    echo

    exit 1

fi


# ------------------------------------------------------------
# Basic MOL2 section validation
# ------------------------------------------------------------

for SECTION in \
    '@<TRIPOS>MOLECULE' \
    '@<TRIPOS>ATOM' \
    '@<TRIPOS>BOND'
do

    if ! grep -q "^${SECTION}" "$INPUT_COPY"; then

        echo
        echo "ERROR: Required MOL2 section was not found:"
        echo
        echo "  $SECTION"
        echo

        exit 1

    fi

done


# ------------------------------------------------------------
# Check number of molecules
#
# For the present workflow:
# one MOL2 file = one ligand molecule.
# ------------------------------------------------------------

MOLECULE_COUNT=$(
    grep -c '^@<TRIPOS>MOLECULE' "$INPUT_COPY" || true
)


if [[ "$MOLECULE_COUNT" -ne 1 ]]; then

    echo
    echo "ERROR: This workflow expects one ligand per MOL2 file."
    echo
    echo "Detected molecules:"
    echo "  $MOLECULE_COUNT"
    echo

    exit 1

fi


# ------------------------------------------------------------
# Validate ligand MOL2
#
# Obtain:
#   atom count
#   bond count
#   hydrogen count
#   total partial charge
#   atom types
#   coordinate ranges
#   malformed atom lines
# ------------------------------------------------------------

VALIDATION=$(
python3 - "$INPUT_COPY" <<'PY'

from pathlib import Path
import sys


path = Path(sys.argv[1])

lines = path.read_text().splitlines()


in_atom = False
in_bond = False

natoms = 0
nbonds = 0
nhydrogen = 0

charge = 0.0

bad_atom_lines = 0
bad_charge_lines = 0

atom_types = {}

xs = []
ys = []
zs = []


for line in lines:

    stripped = line.strip()


    if stripped == "@<TRIPOS>ATOM":

        in_atom = True
        in_bond = False

        continue


    if stripped == "@<TRIPOS>BOND":

        in_atom = False
        in_bond = True

        continue


    if stripped.startswith("@<TRIPOS>"):

        in_atom = False
        in_bond = False

        continue


    # --------------------------------------------------------
    # ATOM section
    # --------------------------------------------------------

    if in_atom and stripped:

        f = line.split()

        if len(f) < 9:

            bad_atom_lines += 1
            continue


        natoms += 1


        # Coordinates

        try:

            x = float(f[2])
            y = float(f[3])
            z = float(f[4])

            xs.append(x)
            ys.append(y)
            zs.append(z)

        except ValueError:

            bad_atom_lines += 1


        # Atom type

        atom_type = f[5]

        atom_types[atom_type] = (
            atom_types.get(atom_type, 0)
            + 1
        )


        # Hydrogen detection

        atom_name = f[1].upper()
        atom_type_upper = atom_type.upper()

        if (
            atom_name.startswith("H")
            or
            atom_type_upper == "H"
            or
            atom_type_upper.startswith("H.")
        ):

            nhydrogen += 1


        # Partial charge

        try:

            q = float(f[8])
            charge += q

        except ValueError:

            bad_charge_lines += 1


    # --------------------------------------------------------
    # BOND section
    # --------------------------------------------------------

    elif in_bond and stripped:

        f = line.split()

        if len(f) >= 4:
            nbonds += 1


# ------------------------------------------------------------
# Results
# ------------------------------------------------------------

print(f"ATOMS={natoms}")
print(f"BONDS={nbonds}")
print(f"HYDROGENS={nhydrogen}")
print(f"CHARGE={charge:.6f}")
print(f"BAD_ATOMS={bad_atom_lines}")
print(f"BAD_CHARGES={bad_charge_lines}")


if xs:

    print(f"XRANGE={min(xs):.3f}|{max(xs):.3f}")
    print(f"YRANGE={min(ys):.3f}|{max(ys):.3f}")
    print(f"ZRANGE={min(zs):.3f}|{max(zs):.3f}")

else:

    print("XRANGE=NA")
    print("YRANGE=NA")
    print("ZRANGE=NA")


for atom_type in sorted(atom_types):

    print(
        "TYPE="
        + atom_type
        + "|"
        + str(atom_types[atom_type])
    )

PY
)


# ------------------------------------------------------------
# Parse validation results
# ------------------------------------------------------------

ATOM_COUNT=$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="ATOMS"{print $2}'
)


BOND_COUNT=$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="BONDS"{print $2}'
)


H_COUNT=$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="HYDROGENS"{print $2}'
)


TOTAL_CHARGE=$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="CHARGE"{print $2}'
)


BAD_ATOMS=$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="BAD_ATOMS"{print $2}'
)


BAD_CHARGES=$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="BAD_CHARGES"{print $2}'
)


XRANGE=$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="XRANGE"{print $2}'
)


YRANGE=$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="YRANGE"{print $2}'
)


ZRANGE=$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="ZRANGE"{print $2}'
)


ATOM_TYPES=$(
    printf '%s\n' "$VALIDATION" \
        | awk -F= '$1=="TYPE"{print $2}'
)


# ------------------------------------------------------------
# Basic validation
# ------------------------------------------------------------

if [[ "$ATOM_COUNT" -eq 0 ]]; then

    echo
    echo "ERROR: No ligand atoms were detected."
    echo

    exit 1

fi


if [[ "$BOND_COUNT" -eq 0 ]]; then

    echo
    echo "ERROR: No ligand bonds were detected."
    echo

    exit 1

fi


if [[ "$BAD_ATOMS" -ne 0 ]]; then

    echo
    echo "ERROR: Malformed MOL2 atom records were detected."
    echo
    echo "Number of problematic records:"
    echo "  $BAD_ATOMS"
    echo

    exit 1

fi


if [[ "$BAD_CHARGES" -ne 0 ]]; then

    echo
    echo "ERROR: Invalid partial charge records were detected."
    echo
    echo "Number of problematic records:"
    echo "  $BAD_CHARGES"
    echo

    exit 1

fi


# ------------------------------------------------------------
# Warn if no hydrogen atoms were found
# ------------------------------------------------------------

if [[ "$H_COUNT" -eq 0 ]]; then

    echo
    echo "============================================================"
    echo " WARNING"
    echo "============================================================"
    echo
    echo "No explicit hydrogen atoms were detected."
    echo
    echo "The ligand MOL2 is expected to be prepared before"
    echo "this script is executed."
    echo

fi


# ------------------------------------------------------------
# Check suspicious atom types
# ------------------------------------------------------------

SUSPICIOUS_TYPES=$(
python3 - "$INPUT_COPY" <<'PY'

from pathlib import Path
import sys


path = Path(sys.argv[1])

in_atom = False

bad = []


SUSPICIOUS = {
    "DU",
    "DUMMY",
    "LP",
    "X",
    "*",
}


for line in path.read_text().splitlines():

    stripped = line.strip()


    if stripped == "@<TRIPOS>ATOM":

        in_atom = True
        continue


    if (
        stripped.startswith("@<TRIPOS>")
        and
        stripped != "@<TRIPOS>ATOM"
    ):

        in_atom = False
        continue


    if not in_atom or not stripped:
        continue


    f = line.split()


    if len(f) < 6:
        continue


    atom_type = f[5].upper()


    if atom_type in SUSPICIOUS:

        bad.append(line)


for line in bad:

    print(line)

PY
)


if [[ -n "$SUSPICIOUS_TYPES" ]]; then

    echo
    echo "============================================================"
    echo " WARNING"
    echo "============================================================"
    echo
    echo "Suspicious MOL2 atom types were detected:"
    echo

    printf '%s\n' "$SUSPICIOUS_TYPES"

    echo

fi


# ------------------------------------------------------------
# Check MOL2 SET count compatibility
#
# Same compatibility issue observed previously for
# AmberTools-generated receptor MOL2 files.
#
# Ligands prepared by other programs may also contain an
# inconsistent SET count, so check rather than assume.
# ------------------------------------------------------------

echo
echo "------------------------------------------------------------"
echo "Checking MOL2 compatibility"
echo "------------------------------------------------------------"
echo


python3 - "$INPUT_COPY" "$OUTPUT" <<'PY'

from pathlib import Path
import sys


src = Path(sys.argv[1])
dst = Path(sys.argv[2])

lines = src.read_text().splitlines()


try:

    mol_index = next(
        i
        for i, line in enumerate(lines)
        if line.strip() == "@<TRIPOS>MOLECULE"
    )

except StopIteration:

    raise SystemExit(
        "ERROR: @<TRIPOS>MOLECULE was not found."
    )


counts_index = mol_index + 2


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


print("Counts line before:")
print(" ", lines[counts_index])

print()

print(
    "@<TRIPOS>SET:",
    "present" if has_set else "absent"
)


# ------------------------------------------------------------
# Correct inconsistent SET count
# ------------------------------------------------------------

if not has_set and fields[4] != "0":

    old = fields[4]

    fields[4] = "0"

    lines[counts_index] = (
        "  "
        + "   ".join(fields)
    )

    print()
    print(
        f"SET count corrected: {old} -> 0"
    )

else:

    print()
    print("SET count does not require correction.")


dst.write_text(
    "\n".join(lines) + "\n"
)


print()

print("Counts line after:")
print(" ", lines[counts_index])

PY


# ------------------------------------------------------------
# Check final output
# ------------------------------------------------------------

if [[ ! -s "$OUTPUT" ]]; then

    echo
    echo "ERROR: LIG_DOCK.mol2 was not generated."
    echo

    exit 1

fi


# ------------------------------------------------------------
# Final MOL2 counts line
# ------------------------------------------------------------

MOL2_COUNTS=$(
python3 - "$OUTPUT" <<'PY'

from pathlib import Path
import sys


lines = Path(sys.argv[1]).read_text().splitlines()


for i, line in enumerate(lines):

    if line.strip() == "@<TRIPOS>MOLECULE":

        if i + 2 < len(lines):
            print(lines[i + 2])

        break

PY
)


# ------------------------------------------------------------
# Write summary
# ------------------------------------------------------------

{
    echo "============================================================"
    echo " DOCK6 ligand preparation summary"
    echo "============================================================"
    echo

    echo "[Input]"
    echo "Selected ligand        : $INPUT"
    echo "Copied input           : $INPUT_COPY"
    echo

    echo "[Structure]"
    echo "Molecules              : $MOLECULE_COUNT"
    echo "Atoms                  : $ATOM_COUNT"
    echo "Bonds                  : $BOND_COUNT"
    echo "Hydrogens              : $H_COUNT"
    echo "Total partial charge   : $TOTAL_CHARGE"
    echo

    echo "[Coordinate ranges]"
    echo "X                      : $XRANGE"
    echo "Y                      : $YRANGE"
    echo "Z                      : $ZRANGE"
    echo

    echo "[MOL2]"
    echo "Counts line            : $MOL2_COUNTS"
    echo

    echo "[Atom types]"

    if [[ -n "$ATOM_TYPES" ]]; then

        while IFS='|' read -r TYPE COUNT; do

            printf "  %-15s %s\n" \
                "$TYPE" \
                "$COUNT"

        done <<< "$ATOM_TYPES"

    fi

    echo

    echo "[Validation]"
    echo "Malformed atom lines   : $BAD_ATOMS"
    echo "Invalid charges        : $BAD_CHARGES"
    echo

    echo "[Output]"
    echo "Original copy          : $INPUT_COPY"
    echo "DOCK6 ligand           : $OUTPUT"

} > "$SUMMARY"


# ------------------------------------------------------------
# Final report
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Ligand preparation completed"
echo "============================================================"
echo

echo "Atoms:"
echo "  $ATOM_COUNT"
echo

echo "Bonds:"
echo "  $BOND_COUNT"
echo

echo "Hydrogens:"
echo "  $H_COUNT"
echo

echo "Total partial charge:"
echo "  $TOTAL_CHARGE"
echo

echo "Atom types:"
echo


if [[ -n "$ATOM_TYPES" ]]; then

    while IFS='|' read -r TYPE COUNT; do

        printf "  %-15s %s\n" \
            "$TYPE" \
            "$COUNT"

    done <<< "$ATOM_TYPES"

fi


echo
echo "Generated files:"
echo

echo "  $INPUT_COPY"
echo "  $OUTPUT"
echo "  $SUMMARY"
echo

echo "Ligand for DOCK6:"
echo
echo "  $OUTPUT"
echo