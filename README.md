# TP 3 — Infrastructure as Code : automatiser le registre (Terraform + Ansible)

Ce TP **automatise** le déploiement réalisé à la main au [TP 2 ClickOps](../tp-aws-clickops/).
Tout ce qui était clics + SSH + commandes devient **deux commandes reproductibles**.

## Le principe : provisionner, puis configurer

| Outil | Rôle | Ce qu'il fait ici |
| --- | --- | --- |
| **Terraform** | *Provisionnement* (créer l'infra) | Crée la clé SSH, le Security Group et l'instance EC2 |
| **Ansible** | *Configuration* (préparer la machine) | Installe Docker et déploie la pile du registre |

## Architecture / flux

```text
  Toi (terraform apply) ─────► AWS : clé SSH + Security Group + EC2
                                          │ (output : IP publique)
                                          ▼
  Toi (ansible-playbook) ──SSH──► EC2 : install Docker + registry:2 + UI
                                          │
  Ton PC (docker push) ──:5000──────────► registre opérationnel
```

## Contenu du dossier `registry/`

| Fichier | Rôle |
| --- | --- |
| `main.tf` | Terraform : provider AWS, AMI Ubuntu, clé SSH, Security Group, EC2, sortie IP |
| `playbook.yml` | Ansible : installe Docker + déploie la pile du registre |
| `inventory.ini.example` | Gabarit d'inventaire (y mettre l'IP de sortie de Terraform) |
| `docker-compose.yml` | Template (l'IP `{{ public_ip }}` est injectée par Ansible) |
| `.gitignore` | Exclut l'état Terraform, la clé `.pem`, l'inventaire réel |

## Prérequis

- **Terraform** ≥ 1.5 et **Ansible** installés (le playbook n'utilise que des
  modules `ansible.builtin`).
- Un **compte AWS** + identifiants configurés (`aws configure`, ou variables
  d'environnement `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`).

## Déroulé

Toutes les commandes se lancent depuis le dossier `registry/`.

### 1. Provisionner l'infrastructure (Terraform)

```bash
cd registry
terraform init      # télécharge les providers aws / tls / local
terraform apply     # tape "yes" ; note la sortie  instance_ip = X.X.X.X
```

Terraform crée la clé `registry-key-terraform.pem` (permissions `0400`), le
Security Group et l'EC2.

### 2. Configurer la machine (Ansible)

```bash
cp inventory.ini.example inventory.ini
# édite inventory.ini : remplace <IP_PUBLIQUE_AWS> par l'instance_ip ci-dessus
ansible-playbook -i inventory.ini playbook.yml
```

Le playbook installe Docker, crée l'utilisateur du registre (`admin` / `admin123`)
et démarre la pile (`docker compose up -d`).

### 3. Tester depuis ton PC

```bash
# Ajoute "<IP>:5000" à insecure-registries (daemon.json) puis redémarre Docker
docker login <IP>:5000        # admin / admin123
docker pull hello-world
docker tag hello-world <IP>:5000/test-iac:v1
docker push <IP>:5000/test-iac:v1
```

Interface web : `http://<IP>` (port 80).

## ⚠️ Nettoyage — la magie de l'IaC

```bash
cd registry
terraform destroy     # détruit l'EC2, le Security Group et la clé → retour à 0 €
```

Une seule commande supprime **proprement tout** ce que Terraform a créé : plus de
ressource oubliée, plus de facturation surprise.

## Sécurité

- **`*.tfstate` n'est JAMAIS versionné** : l'état Terraform contient la **clé privée
  RSA en clair** (voir `.gitignore`). C'est le point de sécurité n°1 de l'IaC.
- `*.pem` (clé) et `inventory.ini` (IP réelle) sont également ignorés par git.
- `admin123` = **défaut de laboratoire documenté**, pas un secret réel.
- SSH (port 22) ouvert à `0.0.0.0/0` pour le TP — **à restreindre à son IP** en vrai.

## ClickOps vs IaC — le gain

| Aspect | ClickOps (TP 2, manuel) | IaC (ce TP) |
| --- | --- | --- |
| Création | clics + SSH, ~30 min | `terraform apply`, ~2 min |
| Reproductibilité | faible (gestes manuels) | totale (code versionné) |
| Erreurs humaines | élevées | quasi nulles |
| Destruction | manuelle (risque d'oubli) | `terraform destroy` |

## Note : version simplifiée

Conformément au support, cette version est **simplifiée** : registre en **HTTP sur
le port 5000** (`insecure-registries`), **sans Nginx ni SSL** — pour se concentrer
sur Terraform/Ansible. En production, on garderait le **reverse proxy + SSL** du
[TP 2 ClickOps](../tp-aws-clickops/).

## Écarts avec le support de cours

Le playbook diffère volontairement des slides sur 3 points :

- **htpasswd en bcrypt** (`htpasswd -B`) au lieu du module `htpasswd` : le registre
  Docker n'accepte **que** le bcrypt ; le module génère du MD5 → erreur `401` au
  `docker login`. *(Correction nécessaire, vérifiée en test.)*
- **`docker compose up -d --force-recreate`** : recrée le conteneur pour qu'il
  recharge le fichier d'authentification après une ré-exécution.
- **Modules en nom complet** (`ansible.builtin.*`) et **aucune dépendance
  `community.general`** : bonne pratique, plus robuste.

## Rattachement aux principes

- **GitOps / Infrastructure as Code** : l'infra est décrite par du code versionné.
- **Automation** (CALMS) : zéro geste manuel, déploiement reproductible.
- C'est la réponse directe à la pénibilité du déploiement manuel du TP précédent.
