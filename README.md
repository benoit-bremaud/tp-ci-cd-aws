# TP — Automatiser un registre Docker **sécurisé** (HTTPS) avec Terraform + Ansible

Ce TP **automatise de bout en bout** le déploiement d'un registre Docker privé
**sécurisé** sur AWS : reverse proxy **Nginx** + **certificat SSL (HTTPS)**.
Tout ce qui était clics + SSH + commandes manuelles devient **deux commandes
reproductibles** : `terraform apply` puis `ansible-playbook`.

> **Objectif pédagogique :** personne ne se connecte en SSH pour configurer quoi que
> ce soit. L'infrastructure (Terraform) et la configuration (Ansible) sont décrites
> par du **code versionné** → on recrée tout à l'identique en ~3 minutes.

---

## 1. Ce que tu vas construire

```text
  terraform apply ──► AWS : clé SSH + Security Group (22, 443) + EC2 (IP publique)
                                    │ (sortie : instance_ip = X.X.X.X)
                                    ▼
  ansible-playbook ──SSH──► EC2 : Docker + certif SSL + Nginx + registry:2 + UI
                                    │
        Internet ──HTTPS :443──► Nginx ──┬─ /v2/ ─► registry:2  (port 5000, INTERNE)
                                         └─  /   ─► UI joxit     (port 80,   INTERNE)
```

**L'image à retenir** 🏢 : un bâtiment avec **un seul gardien à l'entrée**.

| Service | Rôle | Image |
| --- | --- | --- |
| `registry:2` | stocke les images | l'**entrepôt** (aucun port public) |
| `joxit/docker-registry-ui` | affiche les images | l'**accueil** (aucun port public) |
| `nginx:alpine` | proxy SSL (443) | le **gardien** : seul exposé, vérifie le badge (SSL) et oriente |

Nginx termine le HTTPS et **aiguille** : `…/v2/…` (API Docker) → registre ; le reste
→ interface web. Le registre et l'UI ne sont **jamais** exposés directement sur internet.

---

## 2. Prérequis

- **Terraform** ≥ 1.5 et **Ansible** installés.
  ```bash
  terraform version    # doit afficher v1.5+
  ansible --version    # doit afficher ansible-core 2.x
  ```
- Un **compte AWS** + des **identifiants** configurés (une seule fois) :
  ```bash
  aws configure        # colle Access Key ID + Secret + region = eu-west-3
  ```
  > 💡 **Tip :** `aws configure` enregistre les clés dans `~/.aws/` → elles
  > **persistent** entre les sessions, pas besoin de les re-saisir. (Alternative :
  > variables d'env `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, mais elles
  > disparaissent à la fermeture du terminal.)
- **Docker** en local (uniquement si tu veux pousser une image depuis ton PC).

---

## 3. Contenu du dossier `registry/`

| Fichier | Rôle |
| --- | --- |
| `main.tf` | **Terraform** : provider AWS, AMI Ubuntu, clé SSH, Security Group (22 + 443), EC2, sortie de l'IP |
| `playbook.yml` | **Ansible** : Docker + génère le certif SSL + pose `nginx.conf` + démarre la pile |
| `nginx.conf` | Config Nginx (template) : routage `/v2/`→registre, reste→UI, chemins SSL |
| `docker-compose.yml` | La pile (template) : `registry` + `ui` (internes) + `nginx` (443) |
| `inventory.ini.example` | Gabarit d'inventaire Ansible (y mettre l'IP de sortie de Terraform) |
| `.gitignore` | Exclut l'état Terraform, la clé `.pem`, l'inventaire réel, les certs SSL |

> 💡 **`{{ public_ip }}`** dans `nginx.conf` et `docker-compose.yml` = un **placeholder**.
> Ansible le remplace par l'IP réelle au déploiement (module `template`).

---

## 4. Déroulé pas-à-pas (reproduction complète)

Toutes les commandes se lancent depuis le dossier **`registry/`**.

### Étape 0 — Vérifier l'accès AWS
```bash
aws sts get-caller-identity    # doit renvoyer ton numéro de compte = OK
```
> 💡 Si ça renvoie une erreur de credentials → refais `aws configure`.

### Étape 1 — Provisionner l'infrastructure (Terraform)
```bash
cd registry
terraform init      # télécharge les providers aws / tls / local (1re fois seulement)
terraform apply     # tape "yes" ; note la sortie  instance_ip = X.X.X.X
```
Terraform crée : la clé `registry-key-terraform.pem` (perms `0400`), le Security
Group (ports 22 + 443) et l'instance EC2 `t3.micro`.

> ⚠️ **Tip n°1 (le piège classique) :** `terraform apply` crée une **nouvelle IP à
> chaque fois**. Reporte cette **nouvelle** `instance_ip` partout dans la suite.

### Étape 2 — Configurer la machine (Ansible)
```bash
cp inventory.ini.example inventory.ini
# édite inventory.ini : remplace <IP_PUBLIQUE_AWS> par l'instance_ip de l'étape 1
# (ou en une ligne :)  sed -i 's/<IP_PUBLIQUE_AWS>/X.X.X.X/' inventory.ini
ansible-playbook -i inventory.ini playbook.yml
```
Le playbook (idempotent) : installe Docker, **génère le certificat SSL auto-signé**
(CN = ton IP), pose `nginx.conf`, crée l'utilisateur `admin` / `admin123` (htpasswd
**bcrypt**) et démarre la pile. Résultat attendu : `failed=0`.

> 💡 **Tip :** le playbook attend que SSH soit prêt. Si la 1re exécution échoue en
> `UNREACHABLE`, l'EC2 démarre encore — attends ~30 s et relance la même commande.

### Étape 3 — Vérifier que tout marche

**a) En ligne de commande** (le plus rapide, depuis n'importe où) :
```bash
# -k = on accepte le certificat auto-signé. Doit renvoyer {"repositories":[...]}
curl -sk -u admin:admin123 https://X.X.X.X/v2/_catalog
```

**b) Dans le navigateur (= ta capture / livrable)** :
- Ouvre **`https://X.X.X.X`**
- Avertissement de sécurité (certif auto-signé) → **« Avancé »** → **« Continuer »**.
  > 💡 C'est **normal et attendu** : un certificat auto-signé n'est pas reconnu par
  > une autorité, mais le chiffrement HTTPS fonctionne quand même.
- Tu vois l'**interface du registre**. 📸

**c) Pousser une image de test** (deux méthodes au choix) :

*Méthode 1 — depuis le serveur (propre, ne touche pas ton Docker local) :*
```bash
ssh -i registry-key-terraform.pem -o StrictHostKeyChecking=no ubuntu@X.X.X.X
# une fois connecté, on fait confiance au certif puis on pousse :
sudo mkdir -p "/etc/docker/certs.d/X.X.X.X:443"
sudo cp /home/ubuntu/registry-stack/ssl/registry.crt "/etc/docker/certs.d/X.X.X.X:443/ca.crt"
echo admin123 | sudo docker login X.X.X.X:443 -u admin --password-stdin
sudo docker pull alpine:3.20
sudo docker tag alpine:3.20 X.X.X.X:443/demo-https:v1
sudo docker push X.X.X.X:443/demo-https:v1
```

*Méthode 2 — depuis ton PC (la manip du sujet) :*
```bash
# 1. Ajoute "X.X.X.X:443" à insecure-registries dans /etc/docker/daemon.json
# 2. Redémarre Docker : sudo systemctl restart docker
docker login X.X.X.X:443 -u admin -p admin123
docker tag alpine:3.20 X.X.X.X:443/demo-https:v1
docker push X.X.X.X:443/demo-https:v1
```
> 💡 **Tip « 2 months ago » :** la date affichée par l'UI = la date de **fabrication
> de l'image** (ex. `alpine` buildée il y a 2 mois sur Docker Hub), **pas** la date
> du push. Rien d'anormal.

### Étape 4 — Nettoyage (ESSENTIEL pour le coût) 🗑️
```bash
terraform destroy     # tape "yes" → supprime EC2 + Security Group + clé → 0 €
```
> ⚠️ **Fais ta capture AVANT de détruire** : ensuite le serveur disparaît et l'URL
> ne répond plus. Une **seule** commande supprime tout ce que Terraform a créé →
> zéro ressource oubliée, zéro facture surprise.

---

## 5. Tips & pièges à connaître (mémo)

| Piège | À faire |
| --- | --- |
| **Nouvelle IP** à chaque `terraform apply` | reporter la nouvelle IP dans `inventory.ini` + `docker login` + navigateur |
| **Console AWS** : « rien à voir » | choisir la région **Europe (Paris) `eu-west-3`** en haut à droite |
| **`401 Unauthorized`** au `docker login` | le registre n'accepte **que** le bcrypt → htpasswd avec `-B` (déjà dans le playbook) |
| **Certif refusé** par Docker | côté serveur : `certs.d` ; côté PC : `insecure-registries` + redémarrer Docker |
| **Identifiants AWS** dans un nouveau terminal | refaire `aws configure` (ou ré-exporter les variables d'env) |

---

## 6. Dépannage (erreurs courantes)

- **`Error: No valid credential sources found`** (Terraform) → identifiants AWS absents
  → `aws configure`.
- **`UNREACHABLE` / timeout SSH** (Ansible) → l'EC2 démarre encore → attendre 30 s,
  relancer. Vérifier que le port 22 est ouvert dans le Security Group.
- **`docker login` → 401** → mot de passe non-bcrypt. Le playbook utilise déjà
  `htpasswd -B`. Si tu as ré-exécuté, le `--force-recreate` recharge l'auth.
- **`curl` → `HTTP 000`** → le serveur n'existe pas / plus (détruit, ou mauvaise IP).
- **Navigateur : « Not Secure »** → normal (certif auto-signé), clique « Continuer ».

---

## 7. Sécurité

- **`*.tfstate` n'est JAMAIS versionné** : l'état Terraform contient la **clé privée
  RSA en clair** (voir `.gitignore`). C'est le point de sécurité n°1 de l'IaC.
- `*.pem` (clé SSH), `inventory.ini` (IP réelle) et `ssl/` (**certificat + clé privée
  SSL**) sont également ignorés par git.
- `admin` / `admin123` = **défaut de laboratoire documenté**, pas un secret réel.
  À changer pour un vrai usage.
- SSH (port 22) ouvert à `0.0.0.0/0` pour le TP → **à restreindre à son IP** en prod.
- Certificat **auto-signé** = labo uniquement. En prod : certificat d'une autorité
  reconnue (ex. Let's Encrypt, qui nécessite un nom de domaine).

---

## 8. Écarts avec le support de cours

Le playbook diffère volontairement des slides sur 3 points :

- **htpasswd en bcrypt** (`htpasswd -B`) au lieu du module `htpasswd` : le registre
  Docker n'accepte **que** le bcrypt ; le module génère du MD5 → erreur `401` au
  `docker login`. *(Correction nécessaire, vérifiée en test.)*
- **`docker compose up -d --force-recreate`** : recrée le conteneur pour qu'il
  recharge le fichier d'authentification après une ré-exécution.
- **Modules en nom complet** (`ansible.builtin.*`), **aucune dépendance
  `community.general`** : plus robuste.

---

## 9. Conformité au sujet (rappel)

| Phase du sujet | Couvert par |
| --- | --- |
| **1. Terraform** : fermer 5000, ouvrir 443 | `main.tf` (Security Group) |
| **2A. Certif SSL** (non-interactif, CN = IP) | tâche `openssl … -subj "/CN={{ public_ip }}"` |
| **2B. Nginx** (`/v2/`→registre, reste→UI) | `nginx.conf` + tâche `template` |
| **2C. Compose** (ports internes, nginx 443, volumes) | `docker-compose.yml` |
| **3. Tests** (login, push, UI HTTPS) | Étape 3 ci-dessus |

---

## 10. ClickOps vs IaC — le gain

| Aspect | ClickOps (manuel) | IaC (ce TP) |
| --- | --- | --- |
| Création | clics + SSH, ~30 min | `terraform apply`, ~2 min |
| Reproductibilité | faible | **totale** (code versionné) |
| Erreurs humaines | élevées | quasi nulles |
| Destruction | manuelle (risque d'oubli) | `terraform destroy` |

**GitOps / Automation (CALMS)** : l'infra et la config sont du **code**, déployable
et destructible à volonté. C'est la réponse directe à la pénibilité du déploiement
manuel.
