## Інфраструктура AWS з використанням Terraform, Jenkins та Argo CD

Цей проєкт демонструє повний цикл розгортання Django-застосунку в AWS з використанням Terraform (інфраструктура), Jenkins (CI) та Argo CD (CD).

---

## Структура проєкту

```text
lesson-8-9/
├── main.tf               # Головний файл, підключення всіх модулів
├── backend.tf            # Налаштування бекенду для стейтів (S3 + DynamoDB)
├── outputs.tf            # Загальні виводи ресурсів
├── variables.tf          # Кореневі змінні
├── modules/
│   ├── s3-backend/       # S3 + DynamoDB для зберігання Terraform state
│   ├── vpc/              # VPC, підмережі, маршрути, Internet Gateway, NAT
│   ├── ecr/              # ECR репозиторій для Docker-образів
│   ├── eks/              # EKS кластер та node group
│   ├── jenkins/          # Jenkins, встановлений через Helm
│   └── argo_cd/          # Argo CD + Helm-чарт з Application'ами
└── charts/
    └── django-app/       # Локальний Helm-чарт (демо)
        ├── templates/    # deployment, service, hpa, configmap
        ├── Chart.yaml
        └── values.yaml
```

### Огляд модулів

- **`modules/s3-backend`** – створює S3-бакет з версіонуванням для `terraform.tfstate` та таблицю DynamoDB для блокування стейту.
- **`modules/vpc`** – формує мережеву інфраструктуру (VPC, публічні/приватні підмережі, Internet Gateway, NAT, таблиці маршрутів).
- **`modules/ecr`** – створює репозиторій **ECR** для зберігання Docker-образів (`lesson-8-ecr`).
- **`modules/eks`** – підіймає керований кластер **Amazon EKS**, node group та IAM-ролі (в т.ч. для доступу до ECR).
- **`modules/jenkins`** – розгортає **Jenkins** у namespace `jenkins` через Helm, додає:
  - `StorageClass`;
  - namespace `jenkins`;
  - service account `jenkins-sa` з IAM-роллю для Kaniko (доступ до ECR);
  - Helm release `jenkins` з JCasC-конфігурацією (seed-job, креденшели GitHub).
- **`modules/argo_cd`** – розгортає **Argo CD** (Helm release `argo_cd`) та окремий Helm-чарт з:
  - ArgoCD `Application`, який слідкує за репозиторієм `devops_test` (`charts/django-app`);
  - `Secret` типу `repository` для підключення GitHub-репозиторію.

---

## Розгортання інфраструктури (Terraform)

Перед початком переконайтеся, що:

- налаштований AWS CLI (`aws configure`);
- встановлені `terraform`, `kubectl`, `helm`;
- є права створювати EKS, ECR, S3, DynamoDB, VPC, IAM ролі.

> Для першого запуску бекенд S3 у `backend.tf` можна залишити закоментованим, щоб стейт був локальним. Пізніше його можна перенести в S3 (див. розділ про бекенд).

### Крок 1. Ініціалізація

```bash
cd lesson-8-9
terraform init
```

**Що відбувається:** завантажуються провайдери (`aws`, `kubernetes`, `helm`) та ініціалізуються модулі (`s3-backend`, `vpc`, `ecr`, `eks`, `jenkins`, `argo_cd`).

### Крок 2. Планування

```bash
terraform plan
```

**Що відбувається:** Terraform показує список ресурсів, які будуть створені/змінені/видалені. На цьому етапі зручно перевірити:

- CIDR-блоки VPC та підмереж;
- назви кластера EKS та ECR-репозиторію;
- інші параметри модулів.

### Крок 3. Застосування

```bash
terraform apply
# підтвердити: yes
```

**Що створюється:**

- S3-бакет та DynamoDB таблиця для стейтів (`modules/s3-backend`);
- VPC з публічними та приватними підмережами (`modules/vpc`);
- репозиторій **ECR** `lesson-8-ecr` (`modules/ecr`);
- кластер **EKS** з node group та OIDC-провайдером (`modules/eks`);
- **Jenkins** (Helm release `jenkins`) (`modules/jenkins`);
- **Argo CD** + Helm-чарт з Application'ами (`modules/argo_cd`).

Після успішного створення оновіть `kubeconfig`, щоб `kubectl` працював з EKS:

```bash
aws eks update-kubeconfig --region eu-central-1 --name eks-cluster-demo
```

---

## Перевірка CI: Jenkins і оновлення Docker-образу

### Доступ до Jenkins

Jenkins розгорнутий в namespace `jenkins`.

Подивитися сервіс:

```bash
kubectl get svc -n jenkins
```

- Якщо тип `LoadBalancer` – відкрийте EXTERNAL-IP/hostname у браузері.
- Якщо `ClusterIP` – використайте порт-форвардинг:

```bash
kubectl port-forward svc/jenkins 8080:80 -n jenkins
```

і відкрийте `http://localhost:8080`.

Облікові дані адміністратора (з `modules/jenkins/values.yaml`):

- логін: `admin`
- пароль: `admin123`

> У реальних середовищах ці дані потрібно винести в секрети.

### Seed job і pipeline

Jenkins налаштований через **Jenkins Configuration as Code (JCasC)** і при старті:

- створює credential `github-token` для доступу до GitHub;
- створює seed-job, який генерує pipeline job для репозиторію:
  - `https://github.com/Ruslan5891/devops_test`

У результаті в UI Jenkins з’являється pipeline (наприклад, `goit-django-docker`), який працює з репозиторієм `devops_test`.

### Логіка Jenkins pipeline

`Jenkinsfile` лежить у репозиторії `devops_test` і містить дві основні стадії:

1. **Build & Push Docker Image**
   - запускається Kubernetes-агент з контейнерами:
     - `kaniko` – збирає Docker-образ без Docker daemon;
     - `git` – для роботи з Git;
   - збирається образ за `Dockerfile` поточного репозиторію;
   - образ пушиться в **Amazon ECR**:
     - реєстр: `122610492747.dkr.ecr.eu-central-1.amazonaws.com`;
     - репозиторій: `lesson-8-ecr`;
     - тег: `v1.0.${BUILD_NUMBER}` (унікальний для кожного білду).

2. **Update Chart Tag in Git**
   - клонування репозиторію `devops_test`;
   - перехід до `charts/django-app/values.yaml`;
   - оновлення рядка `tag: ...` на новий тег образу (`IMAGE_TAG`);
   - `git add`, `git commit`, `git push` у гілку `main`.

**Результат:**  
кожний успішний запуск pipeline створює новий тег образу в ECR і оновлює Helm values-файл у Git (`devops_test`).

### Де подивитися оновлений образ і тег

- **AWS ECR консоль** – репозиторій `lesson-8-ecr` (регіон `eu-central-1`), список тегів: `v1.0.X`.
- **GitHub `devops_test`** – файл `charts/django-app/values.yaml`, поле `image.tag` міститиме останній тег.

---

## Перевірка CD: Argo CD і оновлення релізу

### Доступ до Argo CD

Argo CD розгорнуто в namespace `argocd`.

Подивитися сервіс:

```bash
kubectl get svc -n argocd
```

Сервіс `argocd-server` налаштовано як `LoadBalancer` (див. `modules/argo_cd/values.yaml`), тому UI доступний за:

```text
https://<ARGOCD_LOADBALANCER_IP>
```

Початковий пароль користувача `admin`:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Авторизація:

- користувач: `admin`
- пароль: значення з команди вище.

### Argo CD Application, що слідкує за `devops_test`

У `modules/argo_cd/charts/values.yaml` описане Application з такими параметрами:

- `repoURL`: `https://github.com/Ruslan5891/devops_test`
- `path`: `charts/django-app`
- `targetRevision`: `main`
- `syncPolicy.automated` з `prune: true` та `selfHeal: true`
- `destination`: кластер `https://kubernetes.default.svc`, namespace `default`.

**Що це дає:**

- Argo CD постійно слідкує за гілкою `main` у `devops_test`;
- кожне оновлення `values.yaml` (новий тег образу від Jenkins) автоматично призводить до синхронізації Helm-чарту в кластері EKS.

### Як перевірити, що Argo CD оновив реліз

1. Відкрити Argo CD UI та знайти Application (наприклад, `example-app`).
2. Переконатися, що статус `Synced` і `Healthy`.
3. Відкрити вкладку **History** й побачити новий sync, який відповідає останньому коміту Jenkins у `devops_test`.
4. Додатково перевірити в кластері:

```bash
kubectl get pods -n default
kubectl describe deployment <release-name>-django -n default
```

У полі `Image` в `describe deployment` ви побачите оновлений тег образу (`lesson-8-ecr:v1.0.X`) з ECR.

---

## Налаштування віддаленого backend (S3)

Після того, як модуль `s3-backend` створив S3-бакет і таблицю DynamoDB, можна перенести локальний Terraform state у S3.

1. Відкрийте файл `backend.tf` та **розкоментуйте** блок:

```bash
terraform {
  backend "s3" {
    bucket         = "lesson-8-terraform-state-bucket-test"
    key            = "lesson-8/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

2. Перезапустіть ініціалізацію:

```bash
terraform init
```

Terraform виявить зміну конфігурації бекенду та запропонує **мігрувати локальний стейт у S3** – підтвердьте (`yes`).

3. Перевірте консоль AWS S3 – у бакеті має з’явитися об’єкт `lesson-8/terraform.tfstate`.  
   DynamoDB-таблиця використовується для блокування стейту при одночасних змінах.

---

## Видалення ресурсів

Якщо інфраструктура більше не потрібна:

1. **Видаліть реліз застосунку (якщо використовували локальний Helm-чарт):**

```bash
helm uninstall <назва-релізу> -n default
```

2. **Видаліть ECR-репозиторій з образами:**

```bash
aws ecr delete-repository --repository-name lesson-8-ecr --force --region eu-central-1
```

3. **Знищіть решту інфраструктури через Terraform:**

```bash
cd lesson-8-9
terraform destroy
```

4. **Особливості:**

- якщо в S3-бакеті залишилися файли стейту, видалення бакета може впасти з помилкою;
- у такому разі зайдіть у консоль S3, виконайте **Empty** для бакета, а потім видаліть його;
- переконайтеся, що всі платні ресурси (NAT Gateway, VPC, ECR тощо) видалені, щоб уникнути зайвих нарахувань.
