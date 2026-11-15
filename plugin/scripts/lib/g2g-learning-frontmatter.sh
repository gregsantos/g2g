# g2g-learning-frontmatter.sh — the one parser and validator for the
# frontmatter of a docs/learnings/ file. Sourced, never executed: both
# g2g-learning-check.sh (the grounding validator) and
# g2g-learnings-index.sh (the builder-facing index) call it, so the two
# can never disagree about which learnings are well-formed.
#
# The schema it enforces is the CONTRACT in
# plugin/skills/writing-g2g-learnings/SKILL.md; change them together.
#
# g2g_learning_frontmatter <file>
#   Sets these globals for the caller:
#     fm_id fm_title fm_date fm_track fm_area fm_severity fm_tags
#     fm_symptoms fm_rootcause fm_resolution
#     fm_end     line number of the closing --- delimiter ("" if none)
#     fm_reason  why the frontmatter is invalid ("" when valid)
#   fm_tags is comma-joined, whichever YAML list form the file used.
#   Returns 0 valid; 1 the delimiters parse but a field is invalid (the
#   body after fm_end is still readable); 2 the file is unreadable or its
#   delimiters are missing (there is no body to read).

g2g_learning_fm_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

g2g_learning_frontmatter() {
    local file="$1" fm_line key value item last_list_key=""

    fm_id="" fm_title="" fm_date="" fm_track="" fm_area="" fm_severity=""
    fm_tags="" fm_symptoms="" fm_rootcause="" fm_resolution=""
    fm_end="" fm_reason=""

    if [[ ! -f "$file" ]]; then
        fm_reason="file disappeared before it could be read: $file"
        return 2
    fi
    if [[ "$(sed -n '1p' "$file")" != "---" ]]; then
        fm_reason="missing opening --- delimiter"
        return 2
    fi
    fm_end="$(awk 'NR>1 && $0=="---"{print NR; exit}' "$file")"
    if [[ -z "$fm_end" ]]; then
        fm_reason="missing closing --- delimiter"
        return 2
    fi

    while IFS= read -r fm_line; do
        if [[ "$fm_line" =~ ^([A-Za-z][A-Za-z0-9_]*):[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="$(g2g_learning_fm_trim "${BASH_REMATCH[2]}")"
            last_list_key="$key"
            case "$key" in
                id) fm_id="$value" ;;
                title) fm_title="$value" ;;
                date) fm_date="$value" ;;
                track) fm_track="$value" ;;
                area) fm_area="$value" ;;
                severity) fm_severity="$value" ;;
                tags)
                    value="${value#\[}"; value="${value%\]}"
                    fm_tags="$value"
                    ;;
                symptoms) fm_symptoms="$value" ;;
                rootCause) fm_rootcause="$value" ;;
                resolution) fm_resolution="$value" ;;
                *) ;;
            esac
        elif [[ "$fm_line" =~ ^[[:space:]]*-[[:space:]]+(.*)$ ]]; then
            item="$(g2g_learning_fm_trim "${BASH_REMATCH[1]}")"
            case "$last_list_key" in
                tags)
                    if [[ -n "$fm_tags" ]]; then fm_tags="$fm_tags,$item"; else fm_tags="$item"; fi
                    ;;
                *) ;;
            esac
        fi
    done < <(sed -n "2,$((fm_end - 1))p" "$file")

    local reason=""
    [[ -n "$fm_id" ]] || reason="missing required field: id"
    [[ -n "$reason" || "$fm_id" =~ ^L-[0-9]{3,}$ ]] || reason="id does not match L-NNN: $fm_id"
    [[ -n "$reason" || -n "$fm_title" ]] || reason="missing required field: title"
    [[ -n "$reason" || -n "$fm_date" ]] || reason="missing required field: date"
    [[ -n "$reason" || "$fm_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || reason="date is not YYYY-MM-DD: $fm_date"
    [[ -n "$reason" || -n "$fm_track" ]] || reason="missing required field: track"
    [[ -n "$reason" || "$fm_track" == "bug" || "$fm_track" == "knowledge" ]] || reason="track must be bug or knowledge: $fm_track"
    [[ -n "$reason" || -n "$fm_area" ]] || reason="missing required field: area"
    if [[ -z "$reason" ]]; then
        case "$fm_area" in
            commands|agents|scripts|hooks|templates|tests|evals|ci|config|docs) ;;
            *) reason="area not in enum: $fm_area" ;;
        esac
    fi
    [[ -n "$reason" || -n "$fm_severity" ]] || reason="missing required field: severity"
    if [[ -z "$reason" ]]; then
        case "$fm_severity" in
            critical|high|medium|low) ;;
            *) reason="severity not in enum: $fm_severity" ;;
        esac
    fi
    [[ -n "$reason" || -n "$fm_tags" ]] || reason="missing required field: tags (must be non-empty)"

    if [[ -z "$reason" ]]; then
        if [[ "$fm_track" == "bug" ]]; then
            [[ -n "$fm_symptoms" ]] || reason="bug track missing required field: symptoms"
            [[ -n "$reason" || -n "$fm_rootcause" ]] || reason="bug track missing required field: rootCause"
            [[ -n "$reason" || -n "$fm_resolution" ]] || reason="bug track missing required field: resolution"
        elif [[ "$fm_track" == "knowledge" ]]; then
            if [[ -n "$fm_symptoms" || -n "$fm_rootcause" || -n "$fm_resolution" ]]; then
                reason="knowledge track must omit symptoms/rootCause/resolution"
            fi
        fi
    fi

    fm_reason="$reason"
    [[ -z "$fm_reason" ]] || return 1
    return 0
}
