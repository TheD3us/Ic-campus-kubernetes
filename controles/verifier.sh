#!/usr/bin/env bash
# Controle du projet final M3 — IC-Campus sur Kubernetes (IC-TechDojo, Frazer SADO)
#
# Note le comportement observe sur le cluster, pas les manifestes. Le depot n'est
# lu que pour deux choses : jouer deploy.sh sans variables, et y chercher un
# secret. Destructif pour les donnees de demo (marque, Pod detruit, volume vide
# puis restaure), rejouable a volonte.
#
#   bash controles/verifier.sh [--namespace <ns>] [--hote <fqdn>]
set -uo pipefail

NS=""; HOTE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace|-n) NS="${2:-}"; shift 2 ;;
    --hote|--host)  HOTE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "option inconnue : $1"; exit 2 ;;
  esac
done
[ -n "${NS}" ] || NS="${SESSION_NAMESPACE:-}"
[ -n "${NS}" ] || NS="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)"
[ -n "${NS}" ] || { echo "Aucun namespace : precise --namespace <ns>."; exit 2; }

RACINE="$(cd "$(dirname "$0")/.." && pwd)"
MANIFESTES="${RACINE}/manifests"
DEPLOY="${RACINE}/deploy.sh"

command -v kubectl >/dev/null 2>&1 || { echo "kubectl introuvable."; exit 2; }
kubectl version >/dev/null 2>&1 || { echo "Le serveur d'API ne repond pas."; exit 2; }

nettoyer() {
  kubectl delete pod -n "${NS}" -l ictechdojo.dev/role=controle --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete job -n "${NS}" -l ictechdojo.dev/role=controle --ignore-not-found >/dev/null 2>&1 || true
}
trap nettoyer EXIT
nettoyer

# ── comptabilite ──
TOTAL=0; OBTENU=0
ouvrir() { echo; echo "── $1 ${2:+(${2} points)}"; }
ok()  { OBTENU=$((OBTENU + $1)); TOTAL=$((TOTAL + $1)); printf '  [OK %2d/%-2d] %s\n' "$1" "$1" "$2"; }
ko()  { TOTAL=$((TOTAL + $1)); printf '  [KO  0/%-2d] %s\n' "$1" "$2"; [ $# -gt 2 ] && printf '             %s\n' "$3"; return 0; }
note(){ printf '  [--     ] %s\n' "$1"; }

k()  { kubectl -n "${NS}" "$@" 2>/dev/null; }
jp() { kubectl -n "${NS}" get "$1" "$2" -o jsonpath="$3" 2>/dev/null; }

client() {
  kubectl -n "${NS}" run "ic-ctl-$$-${RANDOM}" --rm -i --restart=Never --quiet \
    --labels=ictechdojo.dev/role=controle --image=busybox:1.37 \
    --command -- sh -c "$1" 2>/dev/null
}

# Commande dans un Pod jetable qui monte le PVC $1 sur /vol.
sur_volume() {
  local nom="ic-ctl-$$-${RANDOM}"
  kubectl -n "${NS}" run "${nom}" --rm -i --restart=Never --quiet \
    --labels=ictechdojo.dev/role=controle --image=busybox:1.37 \
    --overrides="{\"spec\":{\"securityContext\":{\"fsGroup\":0},\"volumes\":[{\"name\":\"v\",\"persistentVolumeClaim\":{\"claimName\":\"$1\"}}],\"containers\":[{\"name\":\"c\",\"image\":\"busybox:1.37\",\"command\":[\"sh\",\"-c\",\"$2\"],\"volumeMounts\":[{\"name\":\"v\",\"mountPath\":\"/vol\"}]}]}}" \
    2>/dev/null
}

# Les fichiers versionnes du depot : tout, sauf .git, img/ et app/ (repris de M2).
fichiers_versionnes() {
  find "${RACINE}" -type f ! -path '*/.git/*' ! -path '*/img/*' ! -path '*/app/*' \
    ! -name '*.jpeg' ! -name '*.jpg' ! -name '*.png' 2>/dev/null
}

# Une valeur (>= 8 caracteres) se retrouve-t-elle dans un fichier versionne ?
fuite_dans_depot() {
  local v="$1" f out=""
  [ -n "${v}" ] && [ "${#v}" -ge 8 ] || return 0
  for f in $(fichiers_versionnes); do
    grep -qIF -- "${v}" "${f}" 2>/dev/null && out="${out} ${f#${RACINE}/}"
  done
  printf '%s' "${out}"
}

attendre_deploiement() {
  local n=0 max="${3:-150}"
  while [ "${n}" -lt "${max}" ]; do
    [ "$(jp deployment "$1" '{.status.availableReplicas}')" = "$2" ] && return 0
    n=$((n + 2)); sleep 2
  done
  return 1
}

attendre_job() {
  local n=0 max="${2:-180}"
  while [ "${n}" -lt "${max}" ]; do
    [ "$(jp job "$1" '{.status.succeeded}')" = "1" ] && return 0
    local f; f="$(jp job "$1" '{.status.failed}')"
    [ -n "${f}" ] && [ "${f}" -ge 4 ] 2>/dev/null && return 1
    n=$((n + 3)); sleep 3
  done
  return 1
}

# ── decouverte : aucun nom d'objet n'est presuppose ──
# L'API est le workload qui declare le port 5000, le portail celui qui declare 8080.
deploiement_par_port() {
  local port="$1" d
  for d in $(k get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    if jp deployment "${d}" '{.spec.template.spec.containers[*].ports[*].containerPort}' | tr ' ' '\n' | grep -qx "${port}"; then
      echo "${d}"; return 0
    fi
  done
  return 1
}

DEP_API="$(deploiement_par_port 5000)"; [ -n "${DEP_API}" ] || DEP_API="ic-api"
DEP_WEB="$(deploiement_par_port 8080)"; [ -n "${DEP_WEB}" ] || DEP_WEB="ic-web"

# Les Services, par le port publie : 5000 pour l'API, 80 pour le portail.
service_par_port() {
  local port="$1" s
  for s in $(k get svc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    if jp service "${s}" '{.spec.ports[*].port}' | tr ' ' '\n' | grep -qx "${port}"; then
      echo "${s}"; return 0
    fi
  done
  return 1
}
SVC_API="$(service_par_port 5000)"; [ -n "${SVC_API}" ] || SVC_API="ic-api"
SVC_WEB="$(service_par_port 80)";   [ -n "${SVC_WEB}" ] || SVC_WEB="ic-web"

echo "═══════════════════════════════════════════════════════════════════════"
echo " IC-Campus sur Kubernetes — controle du projet final M3"
echo " namespace : ${NS}"
echo " date      : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo " workloads : API=${DEP_API:-?}  portail=${DEP_WEB:-?}"
echo " services  : API=${SVC_API:-?}  portail=${SVC_WEB:-?}"
echo "═══════════════════════════════════════════════════════════════════════"

# ═══════════════ 1. IMAGES DANS UN REGISTRE PRIVE, ACCESSIBLES AU CLUSTER — 10 points ═══
ouvrir "1. Images dans un registre prive, accessibles au cluster" 10

img_api="$(jp deployment "${DEP_API}" '{.spec.template.spec.containers[0].image}')"
img_web="$(jp deployment "${DEP_WEB}" '{.spec.template.spec.containers[0].image}')"

pods_prets=0
for d in "${DEP_API}" "${DEP_WEB}"; do
  [ -n "$(jp deployment "${d}" '{.status.readyReplicas}')" ] && pods_prets=$((pods_prets + 1))
done
[ "${pods_prets}" = "2" ] \
  && ok 2 "les deux images tournent : aucune n'est restee en echec de tirage" \
  || ko 2 "un workload au moins n'a aucun replica pret" \
        "kubectl get pods : un ErrImagePull ou un ImagePullBackOff se lit la."

hors_registre=""
for i in "${img_api}" "${img_web}"; do
  case "${i}" in registry.gitlab.com/*) ;; *) hors_registre="${hors_registre} ${i:-<vide>}" ;; esac
done
[ -z "${hors_registre}" ] \
  && ok 2 "les deux images viennent du registre GitLab : ${img_api} et ${img_web}" \
  || ko 2 "image hors du registre GitLab :${hors_registre}" \
        "Le registre de l'entreprise est celui du projet GitLab, sur registry.gitlab.com."

etiquette_figee() {
  case "$1" in
    ""|*:latest|*:) return 1 ;;
    *@sha256:*) return 0 ;;
    *:*[0-9]*)  return 0 ;;
    *) return 1 ;;
  esac
}
flottantes=""
for i in "${img_api}" "${img_web}"; do
  etiquette_figee "${i}" || flottantes="${flottantes} ${i:-<vide>}"
done
[ -z "${flottantes}" ] \
  && ok 2 "tags figes" \
  || ko 2 "tag flottant :${flottantes}" \
        "Une image qui change toute seule entre deux demarrages n'est pas une image de production."

# Tirage anonyme : un jeton sans identifiant, puis le manifeste. 200 = le depot est public.
chemin_api="${img_api#registry.gitlab.com/}"; chemin_api="${chemin_api%%@*}"
etiquette_api="${chemin_api##*:}"; chemin_api="${chemin_api%:*}"
code_anonyme=""
if [ -n "${chemin_api}" ] && [ "${chemin_api}" != "${img_api}" ]; then
  script_anon="tok=\$(curl -s -m 10 'https://gitlab.com/jwt/auth?service=container_registry&scope=repository:${chemin_api}:pull' | sed 's/.*\"token\":\"\\([^\"]*\\)\".*/\\1/'); curl -s -m 10 -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer \$tok\" -H 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json' 'https://registry.gitlab.com/v2/${chemin_api}/manifests/${etiquette_api}'"
  if command -v curl >/dev/null 2>&1; then
    code_anonyme="$(sh -c "${script_anon}" 2>/dev/null | tr -dc '0-9')"
  fi
  if [ -z "${code_anonyme}" ]; then
    code_anonyme="$(kubectl -n "${NS}" run "ic-ctl-anon-${RANDOM}" --rm -i --restart=Never --quiet \
      --labels=ictechdojo.dev/role=controle --image=curlimages/curl:8.11.1 \
      --command -- sh -c "${script_anon}" 2>/dev/null | tr -dc '0-9')"
  fi
fi
if [ -z "${chemin_api}" ] || [ "${chemin_api}" = "${img_api}" ]; then
  ko 1 "depot d'images non mesurable : l'image de l'API n'est pas sur registry.gitlab.com"
elif [ "${code_anonyme}" = "200" ]; then
  ko 1 "le depot d'images est PUBLIC : un tirage anonyme reussit (${code_anonyme})" \
     "Le projet GitLab doit etre prive : ses images sont celles de l'entreprise."
elif [ -n "${code_anonyme}" ]; then
  ok 1 "le depot d'images est prive : tirage anonyme refuse (${code_anonyme})"
else
  ko 1 "le registre n'a pas repondu au tirage anonyme"
fi

# Les Pods se presentent au registre : un Secret de type dockerconfigjson, designe
# par le gabarit du Pod ou par son ServiceAccount.
identifiants_registre=""
sans_identifiant=""
for d in "${DEP_API}" "${DEP_WEB}"; do
  noms="$(jp deployment "${d}" '{.spec.template.spec.imagePullSecrets[*].name}')"
  sa="$(jp deployment "${d}" '{.spec.template.spec.serviceAccountName}')"
  noms="${noms} $(jp serviceaccount "${sa:-default}" '{.imagePullSecrets[*].name}')"
  trouve=0
  for n in ${noms}; do
    if [ "$(jp secret "${n}" '{.type}')" = "kubernetes.io/dockerconfigjson" ]; then
      trouve=1; identifiants_registre="${identifiants_registre} ${n}"
    fi
  done
  [ "${trouve}" = "1" ] || sans_identifiant="${sans_identifiant} ${d}"
done
identifiants_registre="$(printf '%s' "${identifiants_registre}" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
[ -z "${sans_identifiant}" ] \
  && ok 2 "les Pods se presentent au registre avec un identifiant du namespace :${identifiants_registre% }" \
  || ko 2 "aucun identifiant de registre designe par :${sans_identifiant}" \
        "Partie de recherche : comment un Pod tire-t-il une image depuis un registre prive ?"

# Cree en imperatif par deploy.sh, et aucune valeur de cet identifiant dans un fichier versionne.
imperatif=0
if [ -f "${DEPLOY}" ] && grep -qE 'create[[:space:]]+secret[[:space:]]+docker-registry' "${DEPLOY}" 2>/dev/null; then
  imperatif=1
fi
fuites_registre=""
for n in ${identifiants_registre}; do
  brut="$(jp secret "${n}" '{.data.\.dockerconfigjson}')"
  [ -n "${brut}" ] || continue
  clair="$(printf '%s' "${brut}" | base64 -d 2>/dev/null)"
  for v in "${brut}" \
           "$(printf '%s' "${clair}" | grep -o '"auth" *: *"[^"]*"' | sed 's/.*: *"//; s/"$//')" \
           "$(printf '%s' "${clair}" | grep -o '"password" *: *"[^"]*"' | sed 's/.*: *"//; s/"$//')"; do
    fuites_registre="${fuites_registre}$(fuite_dans_depot "${v}")"
  done
done
if [ -z "${identifiants_registre}" ]; then
  ko 1 "rien a mesurer : aucun identifiant de registre deploye"
elif [ "${imperatif}" != "1" ]; then
  ko 1 "deploy.sh ne cree pas l'identifiant de registre par la commande imperative de kubectl" \
     "Cet identifiant ne vit dans aucun fichier : le script le cree depuis deux variables d'environnement."
elif [ -z "${fuites_registre}" ]; then
  ok 1 "identifiant de registre cree en imperatif par deploy.sh, et absent des fichiers versionnes"
else
  ko 1 "identifiant de registre retrouve dans un fichier versionne :${fuites_registre}" \
     "Il vient de deux variables d'environnement, jamais d'un fichier."
fi

# ══════════════════════════════ 2. API ET CATALOGUE QUI SURVIT — 22 points ═══
ouvrir "2. L'API et le catalogue qui survit" 22

pvc_api="$(jp deployment "${DEP_API}" '{range .spec.template.spec.volumes[*]}{.persistentVolumeClaim.claimName}{" "}{end}' | tr -s ' ')"
pvc_donnees="$(printf '%s' "${pvc_api}" | awk '{print $1}')"
[ -n "${pvc_donnees}" ] \
  && ok 3 "l'API reclame un volume persistant : ${pvc_donnees}" \
  || ko 3 "l'API ne monte aucun volume persistant" \
        "Le catalogue vit donc dans le conteneur, et disparait avec lui."

etat_pvc="$(jp pvc "${pvc_donnees:-neant}" '{.status.phase}')"
[ "${etat_pvc}" = "Bound" ] \
  && ok 2 "le volume est lie" \
  || ko 2 "volume en « ${etat_pvc:-absent} »" "Lis ses evenements."

non_root="$(jp deployment "${DEP_API}" '{.spec.template.spec.securityContext.runAsUser}')"
[ -z "${non_root}" ] && non_root="$(jp deployment "${DEP_API}" '{.spec.template.spec.containers[0].securityContext.runAsUser}')"
uid_reel="$(k exec "deployment/${DEP_API}" -- id -u 2>/dev/null | tr -d '\r\n')"
{ [ -n "${uid_reel}" ] && [ "${uid_reel}" != "0" ]; } \
  && ok 3 "le processus de l'API ne tourne pas en root (uid=${uid_reel})" \
  || ko 3 "le processus de l'API tourne en root (uid=${uid_reel:-inconnu})"

sante_api="$(client "wget -q -T 5 -O- http://${SVC_API}:5000/health 2>/dev/null || true")"
printf '%s' "${sante_api}" | grep -q 'ic-campus-api' \
  && ok 1 "la route de sante repond, et c'est bien l'API d'IC-Campus" \
  || ko 1 "la route /health ne repond pas ou ne se nomme pas ic-campus-api" \
        "Reponse lue : ${sante_api:-<aucune>}"

# Le catalogue est servi, et il est complet.
auth="$(k get secret -o jsonpath='{range .items[*]}{.data.API_BASIC_AUTH}{"\n"}{end}' | grep -v '^$' | head -1)"
if [ -n "${auth}" ]; then auth="$(printf '%s' "${auth}" | base64 -d 2>/dev/null)"; fi
cat_direct="$(client "wget -q -T 6 -O- --header='Authorization: Basic ${auth}' http://${SVC_API}:5000/icgroup/api/v1.0/catalog 2>/dev/null || true")"
nb="$(printf '%s' "${cat_direct}" | tr ',' '\n' | grep -c '"id"')"
[ "${nb}" -ge 6 ] 2>/dev/null \
  && ok 3 "l'API sert le catalogue complet (${nb} formations)" \
  || ko 3 "l'API ne sert pas les six formations (${nb} lue(s))" \
        "Le catalogue de reference doit se trouver sur le volume au premier demarrage."

code="$(client "wget -q -T 6 -S -O /dev/null http://${SVC_API}:5000/icgroup/api/v1.0/catalog 2>&1 | grep -o '40[13]' | head -1")"
[ -n "${code}" ] \
  && ok 3 "une requete sans identifiants est refusee (${code})" \
  || ko 3 "une requete sans identifiants n'est pas refusee" \
        "Les identifiants doivent bien parvenir a l'application."

# ── la preuve : la marque survit a la destruction du Pod ──
MARQUE="ICTJ-$(date +%s)-${RANDOM}"
pod_api="$(k get pod -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep "^${DEP_API}-" | head -1)"
marque_posee=0
if [ -n "${pod_api}" ]; then
  k exec "${pod_api}" -c "$(jp pod "${pod_api}" '{.spec.containers[0].name}')" -- sh -c \
    "python3 - <<'EOP'
import json,os
p=os.environ.get('CATALOG_PATH','/data/catalog.json')
d=json.load(open(p))
d['marque']='${MARQUE}'
json.dump(d,open(p,'w'))
EOP" >/dev/null 2>&1 && marque_posee=1
fi
if [ "${marque_posee}" = "1" ]; then
  ok 2 "une marque a pu etre ecrite dans le catalogue depuis le conteneur"
  k delete pod "${pod_api}" --wait=false >/dev/null 2>&1
  sleep 6
  attendre_deploiement "${DEP_API}" "$(jp deployment "${DEP_API}" '{.spec.replicas}')" 150 >/dev/null 2>&1
  sleep 4
  relu="$(sur_volume "${pvc_donnees}" "grep -o ${MARQUE} /vol/catalog.json 2>/dev/null || grep -ro ${MARQUE} /vol 2>/dev/null | head -1")"
  printf '%s' "${relu}" | grep -q "${MARQUE}" \
    && ok 5 "LA MARQUE A SURVECU a la destruction du Pod" \
    || ko 5 "la marque a disparu avec le Pod" \
          "C'est l'incident du 12 mars, reproduit a l'identique."
else
  ko 2 "impossible d'ecrire dans le catalogue depuis le conteneur" \
      "Le processus non root doit pouvoir ecrire sur le volume."
  ko 5 "survie de la donnee non mesurable"
fi

# ═══════════════════════════ 3. CONFIGURATION ET IDENTIFIANTS — 20 points ════
ouvrir "3. Configuration et identifiants" 20

# ── deploy.sh : present, executable, et il refuse de deployer sans ses variables ──
if [ -f "${DEPLOY}" ] && [ -x "${DEPLOY}" ] && head -1 "${DEPLOY}" | grep -q '^#!'; then
  ok 2 "deploy.sh est present a la racine, executable, avec sa ligne d'interprete"
else
  ko 2 "deploy.sh absent, non executable ou sans ligne d'interprete" \
     "Le seul chemin de deploiement est ./deploy.sh, depuis la racine du depot."
fi

# Joue dans un environnement vide, sans aucun acces au cluster : il doit s'arreter
# avant de toucher a quoi que ce soit, en code non nul, en nommant une variable.
if [ -x "${DEPLOY}" ]; then
  vide="$(mktemp -d 2>/dev/null || echo /tmp/ic-ctl-vide-$$)"; mkdir -p "${vide}"
  if command -v timeout >/dev/null 2>&1; then
    sortie_vide="$(cd "${RACINE}" && timeout 30 env -i PATH="${PATH}" HOME="${vide}" KUBECONFIG="${vide}/aucun" bash "${DEPLOY}" 2>&1)"
  else
    sortie_vide="$(cd "${RACINE}" && env -i PATH="${PATH}" HOME="${vide}" KUBECONFIG="${vide}/aucun" bash "${DEPLOY}" 2>&1)"
  fi
  rc_vide=$?
  rm -rf "${vide}" 2>/dev/null
  nomme_variable="$(printf '%s' "${sortie_vide}" | grep -oE '\b[A-Z][A-Z0-9_]{3,}\b' | grep -vE '^(PATH|HOME|KUBECONFIG|WARNING|ERROR|KO|OK)$' | head -1)"
  if [ "${rc_vide}" -ne 0 ] && [ -n "${nomme_variable}" ]; then
    ok 3 "sans variables, deploy.sh s'arrete en code ${rc_vide} et nomme la variable manquante (${nomme_variable})"
  elif [ "${rc_vide}" -ne 0 ]; then
    ko 3 "sans variables, deploy.sh echoue (code ${rc_vide}) mais ne dit pas quelle variable manque" \
       "Un message qui nomme la variable, avant de toucher au cluster."
  else
    ko 3 "sans aucune variable, deploy.sh sort en code 0" \
       "Une variable absente ou vide doit arreter le script : c'est ce qui alerte sur une regression."
  fi
else
  ko 3 "deploy.sh non mesurable"
fi

# Le gabarit des valeurs sensibles : versionne, en stringData ou data, avec des variables et sans valeur.
gabarit=""
for f in $(find "${MANIFESTES}" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null); do
  if grep -q '\${[A-Za-z_][A-Za-z0-9_]*}' "${f}" 2>/dev/null && grep -qE '^[[:space:]]*(stringData|data):' "${f}" 2>/dev/null; then
    gabarit="${gabarit} $(basename "${f}")"
  fi
done
[ -n "${gabarit}" ] \
  && ok 2 "un gabarit versionne porte les valeurs sensibles en variables :${gabarit}" \
  || ko 2 "aucun fichier de manifests/ ne porte de variable \${NOM} sous stringData ou data" \
        "Le fichier versionne porte le nom de la variable, deploy.sh substitue la valeur."

# ── chaque valeur obligatoire est declaree dans le workload, et le processus la recoit ──
env_api="$(k exec "deployment/${DEP_API}" -- env 2>/dev/null)"
env_web="$(k exec "deployment/${DEP_WEB}" -- env 2>/dev/null)"
absentes=""
for v in CATALOG_PATH API_USER API_PASSWORD; do
  printf '%s\n' "${env_api}" | grep -qE "^${v}=." || absentes="${absentes} api:${v}"
done
printf '%s\n' "${env_web}" | grep -qE "^API_BASIC_AUTH=." || absentes="${absentes} web:API_BASIC_AUTH"
[ -z "${absentes}" ] \
  && ok 3 "les quatre valeurs obligatoires arrivent aux processus par l'environnement" \
  || ko 3 "valeur(s) non recue(s) par le processus :${absentes}" \
        "Aucune valeur ne repose sur ce que l'image a fige : c'est l'incident du 2 avril."

# ── rien de sensible en clair : ni dans un objet de configuration, ni en dur dans un workload ──
mdp="$(k get secret -o jsonpath='{range .items[*]}{.data.API_PASSWORD}{"\n"}{end}' | grep -v '^$' | head -1)"
mdp_clair=""; [ -n "${mdp}" ] && mdp_clair="$(printf '%s' "${mdp}" | base64 -d 2>/dev/null)"
auth_clair="${auth}"
sensibles=""
for c in $(k get configmap -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v kube-root-ca); do
  brut_cm="$(kubectl -n "${NS}" get configmap "${c}" -o json 2>/dev/null)"
  if printf '%s' "${brut_cm}" | grep -qiE '"(API_PASSWORD|API_BASIC_AUTH|[A-Z_]*PASSWORD|[A-Z_]*TOKEN|[A-Z_]*WEBHOOK[A-Z_]*)"'; then
    sensibles="${sensibles} configmap/${c}"
  elif [ -n "${mdp_clair}" ] && printf '%s' "${brut_cm}" | grep -qF "${mdp_clair}"; then
    sensibles="${sensibles} configmap/${c}"
  elif [ -n "${auth_clair}" ] && printf '%s' "${brut_cm}" | grep -qF "${auth_clair}"; then
    sensibles="${sensibles} configmap/${c}"
  fi
done
for d in "${DEP_API}" "${DEP_WEB}"; do
  litteraux="$(kubectl -n "${NS}" get deploy "${d}" -o jsonpath='{range .spec.template.spec.containers[*].env[?(@.value)]}{.name}={.value}{"\n"}{end}' 2>/dev/null)"
  if printf '%s' "${litteraux}" | grep -qE '^(API_PASSWORD|API_BASIC_AUTH|[A-Z_]*PASSWORD|[A-Z_]*TOKEN|[A-Z_]*WEBHOOK[A-Z_]*)='; then
    sensibles="${sensibles} ${d}:env-en-dur"
  elif [ -n "${mdp_clair}" ] && printf '%s' "${litteraux}" | grep -qF "${mdp_clair}"; then
    sensibles="${sensibles} ${d}:env-en-dur"
  elif [ -n "${auth_clair}" ] && printf '%s' "${litteraux}" | grep -qF "${auth_clair}"; then
    sensibles="${sensibles} ${d}:env-en-dur"
  fi
done
nb_deploy="$(k get deploy -o name | wc -l | tr -d ' ')"
if [ "${nb_deploy}" -lt 2 ]; then
  ko 4 "rien a mesurer : ${nb_deploy} workload(s) deploye(s) sur 2"
elif [ -z "${sensibles}" ]; then
  ok 4 "aucune valeur sensible en clair : ni dans un objet de configuration, ni en dur dans un workload"
else
  ko 4 "valeur sensible en clair :${sensibles}" \
     "Un objet de configuration n'est pas chiffre, et un workload se lit sans droit particulier."
fi

nb_secret="$(k get secret -o jsonpath='{range .items[*]}{.type}{"\n"}{end}' | grep -c 'Opaque')"
[ "${nb_secret}" -ge 1 ] && [ -n "${mdp}" ] \
  && ok 2 "les identifiants vivent dans un objet fait pour les valeurs sensibles" \
  || ko 2 "aucun objet de type Secret ne porte le mot de passe de l'API"

# ── rien de sensible dans le depot, deploy.sh compris ──
trouves=""
if [ -n "${mdp_clair}" ]; then
  t="$(fuite_dans_depot "${mdp_clair}")"; [ -n "${t}" ] && trouves="${trouves} valeur-en-clair:${t}"
fi
if [ -n "${mdp}" ]; then
  t="$(fuite_dans_depot "${mdp}")"; [ -n "${t}" ] && trouves="${trouves} valeur-encodee:${t}"
fi
if [ -n "${auth_clair}" ]; then
  t="$(fuite_dans_depot "${auth_clair}")"; [ -n "${t}" ] && trouves="${trouves} entete-d-authentification:${t}"
fi
nb_fichiers="$(fichiers_versionnes | wc -l | tr -d ' ')"
if [ "${nb_fichiers}" = "0" ] || [ -z "${mdp}" ]; then
  ko 4 "rien a mesurer : le depot est vide, ou aucun objet sensible n'est deploye" \
     "Le script de verification compare les valeurs reellement deployees au contenu du depot."
elif [ -z "${trouves}" ]; then
  ok 4 "AUCUN SECRET dans les ${nb_fichiers} fichiers versionnes du depot"
else
  ko 4 "secret retrouve dans un fichier versionne :${trouves}" \
     "C'est l'audit du 6 mai. L'historique Git n'oublie rien."
fi

# ══════════════════════════════════════ 4. LE PORTAIL WEB — 12 points ════════
ouvrir "4. Le portail web" 12

rep="$(jp deployment "${DEP_WEB}" '{.status.readyReplicas}')"
[ "${rep:-0}" -ge 2 ] 2>/dev/null \
  && ok 2 "deux replicas du portail repondent (${rep})" \
  || ko 2 "un seul replica du portail pret (${rep:-0})"

ro="$(jp deployment "${DEP_WEB}" '{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}')"
pe="$(jp deployment "${DEP_WEB}" '{.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation}')"
{ [ "${ro}" = "true" ] && [ "${pe}" = "false" ]; } \
  && ok 3 "racine en lecture seule et elevation de privileges interdite, et le conteneur sert" \
  || ko 3 "durcissement absent (lecture seule=${ro:-non}, elevation=${pe:-permise})"

chaine="$(client "wget -q -T 8 -O- --header='Host: ic-web' http://${SVC_WEB}/icgroup/api/v1.0/catalog 2>/dev/null || true")"
printf '%s' "${chaine}" | grep -q '"catalog"' \
  && ok 4 "chaine complete : le portail relaie vers l'API et rend le catalogue" \
  || ko 4 "le portail ne rend pas le catalogue" \
        "Le nom et le port ecrits dans app/nginx/default.conf.template doivent resoudre."

# ── aucune requete perdue pendant un remplacement ──
note "remplacement des replicas du portail, sondage continu…"
perdues=0
k rollout restart "deployment/${DEP_WEB}" >/dev/null 2>&1
i=0
while [ "${i}" -lt 14 ]; do
  r="$(client "wget -q -T 3 -O- http://${SVC_WEB}/health 2>/dev/null || echo PERDUE")"
  printf '%s' "${r}" | grep -q 'PERDUE' && perdues=$((perdues + 1))
  i=$((i + 1))
done
k rollout status "deployment/${DEP_WEB}" --timeout=150s >/dev/null 2>&1
[ "${perdues}" = "0" ] \
  && ok 3 "AUCUNE requete perdue pendant le remplacement (14 sondages)" \
  || ko 3 "${perdues} requete(s) perdue(s) sur 14 pendant le remplacement" \
        "C'est le jeudi 18 h, reproduit. Une readinessProbe, et une strategie de mise a jour qui ne perd pas de capacite."

# ═════════════════════════════════ 5. EXPOSITION PAR TRAEFIK — 16 points ═════
ouvrir "5. L'exposition par Traefik" 16

ing="$(k get ingressroutes.traefik.io -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[ -n "${ing}" ] \
  && ok 2 "une IngressRoute existe : ${ing}" \
  || ko 2 "aucune IngressRoute dans le namespace" \
        "Le fichier fourni/ingressroute.yaml se copie dans manifests/, se corrige, puis se deploie."

portes="$(jp ingressroutes.traefik.io "${ing:-neant}" '{.spec.entryPoints[*]}')"
printf '%s' "${portes}" | tr ' ' '\n' | grep -qx 'websecure' \
  && ok 2 "la route entre par la porte chiffree (entryPoints : ${portes})" \
  || ko 2 "la route n'entre pas par websecure (entryPoints : ${portes:-absents})" \
        "Le portail s'expose en HTTPS, et seulement en HTTPS."

regle="$(jp ingressroutes.traefik.io "${ing:-neant}" '{.spec.routes[0].match}')"
hote_attendu="ic-campus-${NS}.lab.ic-techdojo.com"
if printf '%s' "${regle}" | grep -qF "${hote_attendu}"; then
  ok 2 "la regle designe l'hote attendu : ${hote_attendu}"
else
  ko 2 "la regle ne designe pas ${hote_attendu} (lue : ${regle:-absente})" \
     "L'hote porte le namespace : deux apprenants sur le meme hote se prendraient le trafic l'un de l'autre."
fi

svc_route="$(jp ingressroutes.traefik.io "${ing:-neant}" '{.spec.routes[0].services[0].name}')"
port_route="$(jp ingressroutes.traefik.io "${ing:-neant}" '{.spec.routes[0].services[0].port}')"
if [ "${svc_route}" = "${SVC_WEB}" ] && { [ "${port_route}" = "80" ] || [ "${port_route}" = "$(jp service "${SVC_WEB}" '{.spec.ports[0].name}')" ]; }; then
  ok 2 "la route envoie vers le Service du portail et son port publie (${svc_route}:${port_route})"
else
  ko 2 "la route designe ${svc_route:-<aucun service>}:${port_route:-<aucun port>}, le portail est ${SVC_WEB}:80" \
     "Traefik ne connait que le Service et son port publie, jamais le port du conteneur."
fi

mw="$(k get middlewares.traefik.io -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[ -n "${mw}" ] \
  && ok 2 "le Middleware d'en-tetes est applique dans le namespace : ${mw}" \
  || ko 2 "aucun Middleware Traefik" \
        "Il est fourni : fourni/traefik-entetes-securite.yaml, a appliquer depuis deploy.sh."

mws_route="$(jp ingressroutes.traefik.io "${ing:-neant}" '{.spec.routes[*].middlewares[*].name}')"
printf '%s' "${mws_route}" | tr ' ' '\n' | grep -qx "${mw:-__neant__}" \
  && ok 2 "la route est raccordee a ce Middleware" \
  || ko 2 "la route ne raccorde aucun Middleware (lus : ${mws_route:-aucun})" \
        "Un Middleware present dans le namespace mais absent de la route ne s'applique a rien."

# ── l'en-tete tel que le navigateur le recoit ──
# Par le bord, pas par le Service : l'image emet sa propre politique, seule celle du bord compte.
hote="${HOTE}"
[ -n "${hote}" ] || hote="$(printf '%s' "${regle}" | grep -o 'Host(`[^`]*`)' | head -1 | sed 's/Host(`//; s/`)//')"

entetes=""
if [ -n "${hote}" ]; then
  if command -v curl >/dev/null 2>&1; then
    entetes="$(curl -sS -k -m 15 -D- -o /dev/null "https://${hote}/" 2>/dev/null)"
  fi
  if [ -z "${entetes}" ]; then
    entetes="$(kubectl -n "${NS}" run "ic-ctl-bord-${RANDOM}" --rm -i --restart=Never --quiet \
      --labels=ictechdojo.dev/role=controle --image=curlimages/curl:8.11.1 \
      --command -- sh -c "curl -sS -k -m 15 -D- -o /dev/null https://${hote}/" 2>/dev/null)"
  fi
fi
csp="$(printf '%s' "${entetes}" | grep -i '^content-security-policy' | head -1)"

if [ -z "${hote}" ]; then
  ko 4 "aucun hote lisible dans la regle de l'IngressRoute : la reponse du bord n'est pas mesurable"
elif [ -z "${entetes}" ]; then
  ko 4 "le portail ne repond pas depuis le bord sur https://${hote}/" \
     "Relance avec --hote <fqdn> si ton hote de test differe de celui de l'IngressRoute."
elif [ -z "${csp}" ]; then
  ko 4 "aucune politique de securite de contenu dans la reponse du bord" \
     "Le Middleware est-il bien raccroche a la route qui sert la page ?"
elif ! printf '%s' "${csp}" | grep -q "style-src"; then
  ko 4 "la politique ne dit rien des feuilles de style" \
     "Sans directive style-src, c'est default-src qui s'applique — ici 'none'."
elif ! printf '%s' "${csp}" | grep -q "style-src[^;]*'unsafe-inline'"; then
  ko 4 "la politique interdit les styles EN LIGNE : la page s'affichera sans mise en forme" \
     "Ouvre la console du navigateur : « Applying inline style violates… ». C'est le 4 septembre."
elif printf '%s' "${csp}" | grep -q "script-src[^;]*'unsafe-inline'"; then
  ko 4 "la politique autorise les SCRIPTS en ligne : la porte est ouverte a l'injection de code" \
     "'unsafe-inline' se tolere sur style-src, jamais sur script-src."
else
  ok 4 "la politique sort AU BORD, autorise les styles en ligne d'Angular et refuse les scripts en ligne"
fi

# ═════════════════════════════════════════ 6. LA SAUVEGARDE — 12 points ══════
ouvrir "6. La sauvegarde" 12

cj="$(k get cronjob -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
jb="$(k get job -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v '^ic-ctl-' | head -1)"
if [ -n "${cj}" ]; then
  ok 3 "une tache periodique de sauvegarde existe : ${cj}"
elif [ -n "${jb}" ]; then
  ok 2 "une tache de sauvegarde existe : ${jb} — une tache PERIODIQUE vaut un point de plus"
  TOTAL=$((TOTAL + 1))
else
  ko 3 "aucune tache de sauvegarde" \
     "Partie de recherche : quel objet execute une tache jusqu'a son terme, et quel objet le fabrique a heure fixe ?"
fi

# Volume des archives distinct de celui des donnees.
pvc_sauv=""
for p in $(k get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  [ "${p}" = "${pvc_donnees}" ] && continue
  pvc_sauv="${p}"; break
done
[ -n "${pvc_sauv}" ] \
  && ok 2 "les archives ont leur propre volume : ${pvc_sauv}" \
  || ko 2 "aucun volume distinct pour les archives" \
        "Une sauvegarde sur le meme volume que les donnees disparait avec elles."

# ── declencher la sauvegarde, detruire, restaurer ──
JOBN="ic-ctl-sauv-${RANDOM}"
declenche=0
if [ -n "${cj}" ]; then
  k create job --from="cronjob/${cj}" "${JOBN}" >/dev/null 2>&1 \
    && k label job "${JOBN}" ictechdojo.dev/role=controle --overwrite >/dev/null 2>&1 \
    && declenche=1
elif [ -n "${jb}" ]; then
  kubectl -n "${NS}" get job "${jb}" -o json 2>/dev/null \
    | python3 -c "
import json,sys
j=json.load(sys.stdin)
t=j['spec']['template']
for c in ('creationTimestamp',):
    t.get('metadata',{}).pop(c,None)
n={'apiVersion':'batch/v1','kind':'Job','metadata':{'name':'${JOBN}','labels':{'ictechdojo.dev/role':'controle'}},'spec':{'backoffLimit':j['spec'].get('backoffLimit',2),'template':t}}
n['spec']['template'].setdefault('metadata',{}).setdefault('labels',{})['ictechdojo.dev/role']='controle'
print(json.dumps(n))" 2>/dev/null | kubectl -n "${NS}" apply -f - >/dev/null 2>&1 && declenche=1
fi

if [ "${declenche}" = "1" ] && attendre_job "${JOBN}" 180; then
  ok 2 "la sauvegarde s'execute jusqu'a son terme"
  archives="$(sur_volume "${pvc_sauv:-neant}" "ls -1 /vol 2>/dev/null | head -20")"
  arch="$(printf '%s' "${archives}" | grep -E '\.t(ar\.)?gz$|\.tar$' | tail -1)"
  if [ -n "${arch}" ]; then
    contenu="$(sur_volume "${pvc_sauv}" "tar tzf /vol/${arch} 2>/dev/null || tar tf /vol/${arch} 2>/dev/null")"
    printf '%s' "${contenu}" | grep -q 'catalog.json' \
      && ok 2 "l'archive contient le catalogue" \
      || ko 2 "l'archive ne contient pas catalog.json" "Contenu lu : ${contenu:-vide}"

    # ── destruction, puis restauration depuis l'archive ──
    # Extraction et relecture dans deux Pods distincts : c'est le volume qu'on juge, pas le Pod.
    sur_volume "${pvc_donnees}" "rm -rf /vol/* /vol/.[!.]* 2>/dev/null; true" >/dev/null 2>&1
    sleep 3
    kubectl -n "${NS}" run "ic-ctl-rest-${RANDOM}" --rm -i --restart=Never --quiet \
      --labels=ictechdojo.dev/role=controle --image=busybox:1.37 \
      --overrides="{\"spec\":{\"securityContext\":{\"fsGroup\":0},\"volumes\":[{\"name\":\"d\",\"persistentVolumeClaim\":{\"claimName\":\"${pvc_donnees}\"}},{\"name\":\"s\",\"persistentVolumeClaim\":{\"claimName\":\"${pvc_sauv}\"}}],\"containers\":[{\"name\":\"c\",\"image\":\"busybox:1.37\",\"command\":[\"sh\",\"-c\",\"tar xzf /s/${arch} -C /d 2>/dev/null || tar xf /s/${arch} -C /d; ls -1 /d\"],\"volumeMounts\":[{\"name\":\"d\",\"mountPath\":\"/d\"},{\"name\":\"s\",\"mountPath\":\"/s\"}]}]}}" >/dev/null 2>&1
    sleep 3
    apres="$(sur_volume "${pvc_donnees}" "grep -o ${MARQUE} /vol/catalog.json 2>/dev/null || echo ABSENTE")"
    printf '%s' "${apres}" | grep -q "${MARQUE}" \
      && ok 3 "LA RESTAURATION REND LE CATALOGUE, marque comprise — la sauvegarde vaut quelque chose" \
      || ko 3 "apres restauration, le catalogue ne porte pas la marque ecrite avant la sauvegarde" \
            "C'est le 9 juillet : onze archives, et rien dedans."
    k rollout restart "deployment/${DEP_API}" >/dev/null 2>&1
  else
    ko 2 "aucune archive sur le volume des sauvegardes" "Vu : ${archives:-rien}"
    ko 2 "contenu de l'archive non mesurable"
    ko 3 "restauration non mesurable"
  fi
else
  ko 2 "la sauvegarde n'a pas abouti"
  ko 2 "contenu de l'archive non mesurable"
  ko 3 "restauration non mesurable"
fi

# ═══════════════════════════════════════════════ 7. HYGIENE — 8 points ═══════
ouvrir "7. Hygiene" 8

# Les objets que la plateforme pose elle-meme dans le namespace de session
# (kube-root-ca, les Secrets du tableau de bord Kubernetes) ne sont pas le
# travail de l'apprenant : sans cette exclusion, 3 points sont perdus d'avance
# et le score plein est impossible en session.
sans_etiquette=""
for kind in deployment service configmap secret pvc ingressroutes.traefik.io middlewares.traefik.io cronjob; do
  for o in $(k get "${kind}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v 'kube-root-ca'); do
    case "${o}" in ic-ctl-*|sh.helm.*|kubernetes-dashboard-*) continue ;; esac
    v="$(jp "${kind}" "${o}" '{.metadata.labels.app\.kubernetes\.io/part-of}')"
    [ "${v}" = "ic-campus" ] || sans_etiquette="${sans_etiquette} ${kind}/${o}"
  done
done
nb_objets="$(k get deployment,service,configmap,secret,pvc,ingressroutes.traefik.io,middlewares.traefik.io,cronjob -o name 2>/dev/null | grep -v 'kube-root-ca' | grep -vc 'kubernetes-dashboard-')"
{ [ -z "${sans_etiquette}" ] && [ "${nb_objets}" -ge 6 ]; } \
  && ok 3 "les ${nb_objets} objets du projet portent app.kubernetes.io/part-of: ic-campus" \
  || ko 3 "label normalise absent ou projet incomplet (${nb_objets} objets) :${sans_etiquette}"

manquants=""
for d in "${DEP_API}" "${DEP_WEB}"; do
  for champ in 'requests.cpu' 'requests.memory' 'limits.cpu' 'limits.memory'; do
    c="$(echo "${champ}" | cut -d. -f1)"; r="$(echo "${champ}" | cut -d. -f2)"
    v="$(jp deployment "${d}" "{.spec.template.spec.containers[0].resources.${c}.${r}}")"
    [ -n "${v}" ] || manquants="${manquants} ${d}:${champ}"
  done
done
[ -z "${manquants}" ] \
  && ok 3 "requests ET limits declarees, processeur ET memoire" \
  || ko 3 "valeur(s) manquante(s) :${manquants}" \
        "Un conteneur sans demande est range en BestEffort : premier tue quand le noeud manque."

# kubectl diff sur chaque fichier de manifests/ sans variable ${...} : les gabarits
# substitues par deploy.sh ne peuvent pas etre compares tels quels.
ecarts=""; nb_diff=0
for f in $(find "${MANIFESTES}" -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | sort); do
  grep -q '\${[A-Za-z_][A-Za-z0-9_]*}' "${f}" 2>/dev/null && continue
  nb_diff=$((nb_diff + 1))
  kubectl -n "${NS}" diff -f "${f}" >/dev/null 2>&1 || ecarts="${ecarts} $(basename "${f}")"
done
if [ "${nb_diff}" = "0" ]; then
  ko 2 "manifests/ ne contient aucun fichier comparable" "Le livrable, c'est ce repertoire."
elif [ -z "${ecarts}" ]; then
  ok 2 "kubectl diff sort en 0 sur les ${nb_diff} fichiers comparables : le depot dit la verite sur le cluster"
else
  ko 2 "kubectl diff signale un ecart :${ecarts}" \
     "Un objet cree a la main, ou une correction posee sur un objet vivant sans report."
fi

echo
echo "═══════════════════════════════════════════════════════════════════════"
printf ' SCORE : %d / %d\n' "${OBTENU}" "${TOTAL}"
echo "═══════════════════════════════════════════════════════════════════════"
[ "${OBTENU}" -eq "${TOTAL}" ] && exit 0 || exit 1
