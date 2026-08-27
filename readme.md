# 🚀 GitLab to GitHub Migration Pipeline using GH-GL2GH

> A GitHub Actions based migration workflow for migrating repositories from GitLab to GitHub Enterprise Cloud or GitHub Enterprise Cloud with Data Residency using GitHub Enterprise Importer (GEI) and the `gh-gl2gh` extension.

The workflow provides:

- ✅ Environment validation
- ✅ Migration readiness assessment
- ✅ Manual approval gate
- ✅ Parallel repository migration
- ✅ Post-migration validation
- ✅ GitHub Actions job summaries
- ✅ GitHub, Azure, and AWS intermediate storage support

---

## 📋 Pipeline Execution Model

> ℹ️ **Informational Only**
>
> This section provides a conceptual understanding of the workflow. Actual execution behavior is governed by the GitHub Actions workflow YAML implementation.

This workflow orchestrates a structured GitLab-to-GitHub migration process using GitHub Enterprise Importer (GEI) and the `gh-gl2gh` extension.

### Key Features

- **Manual Approval Gate**  
  When readiness validation is enabled, the workflow pauses after the readiness stage and requires user approval before migration begins.

- **Parallel Repository Migration**  
  Repository migrations are executed in parallel to improve throughput while remaining within the configured concurrency limit.
  
- **Migration Status Tracking**  
  The migration stage generates `repos_with_status.csv`, which tracks successful and failed migrations and is used by downstream validation stages.

- **Post-Migration Validation**  
  Post-migration validation runs automatically after successful migration and validates repositories that migrated successfully.

- **Flexible Intermediate Storage Support**  
  Supports GitHub Storage, Azure Storage, and AWS Storage.

- **GitHub Enterprise Cloud and Data Residency Support**  
  Supports both GitHub Enterprise Cloud and GitHub Enterprise Cloud with Data Residency.

---

### Pipeline Flow

```text
Environment Validation
      ↓
Migration Readiness Check
      ↓
Approval Stage
      ↓
Repository Migration
      ↓
Post-Migration Validation
```

### Notes

- The readiness stage can be enabled or skipped at runtime.
- Repository migration and post-migration validation always run together.

---

### Stage Execution Details

### Stage 1️⃣ Environment Validation

Performs validation checks for:

- Required secrets
- Required variables
- Inventory file availability
- Inventory file headers
- Storage configuration
- Required scripts
- Runner configuration

If validation fails, the workflow stops before migration begins.

---

### Stage 2️⃣ Migration Readiness Check

Checks:

- Open GitLab merge requests
- Running GitLab pipelines
- Pending GitLab pipelines
- GitLab project accessibility

> ⚠️ **IMPORTANT**
>
> If readiness checks are enabled, the workflow pauses after readiness assessment and requires approval before migration continues.

The readiness stage generates logs, artifacts, and a GitHub Actions job summary.

### Approval Gate

The approval stage uses a GitHub Environment configured with required reviewers.

Approvers should review the readiness output before approving migration.

If readiness is skipped, the approval stage is also skipped.

---

### Stage 3️⃣ Repository Migration

Executes:

```text
2_migration.sh
```

Responsibilities:

- Reads repositories from the inventory file
- Runs migration using `gh gl2gh migrate-repo`
- Supports parallel repository migration
- Generates per-repository migration logs
- Tracks migration status
- Generates `output_files/migration/repos_with_status.csv`

This file is used by post-migration validation.

---

### Stage 4️⃣ Post-Migration Validation

Executes:

```text
3_post_migration_validation.sh
```

Validation includes:

- Repository existence validation
- Branch count validation
- Branch name validation
- Default branch validation
- Commit count validation
- Latest SHA validation

If a repository has more than the configured branch validation threshold, validation checks the default branch and a limited set of additional branches.

Generated outputs:

```text
output_files/post_migration_validation/validation-summary_<timestamp>.csv
output_files/post_migration_validation/validation-summary_<timestamp>.md
```

---

## ⚠️ Limitations

### What Gets Migrated

GitHub Enterprise Importer supports migration of:

- Repository content
- Commit history
- Branches
- Tags
- Commit metadata

Migration of additional GitLab metadata depends on GitHub Enterprise Importer capabilities and supported GitLab versions.

### GitHub Actions Runtime Limits

The workflow supports both GitHub-hosted and self-hosted runners.

| Runner Type | Timeout |
|---|---|
| GitHub-hosted runner | 360 minutes |
| Self-hosted runner | 7200 minutes |

GitHub Actions does not support unlimited timeout. For large migration batches, self-hosted runners are recommended.

### Migration Size Limits

Refer to the latest GitHub Enterprise Importer documentation for supported migration limits and repository size constraints.

Reference: [Understand migrations from GitLab to GitHub](https://docs.github.com/en/migrations/using-github-enterprise-importer/migrate-from-gitlab/understand-migrations)

---

## ⚙️ Prerequisites

Before running the workflow, complete the following setup.

### 1️⃣ GitHub Actions Runner

The workflow supports:

| Runner Type | Description |
|---|---|
| GitHub-hosted runner | Uses `ubuntu-latest` |
| Self-hosted runner | Uses the runner label provided during workflow execution |

The runner must support Linux-based execution.

---

### 2️⃣ Required Tools

The workflow validates and installs required tools when the runner has `sudo` access.

Required tools:

```text
curl
jq
git
gh
```

If using a self-hosted runner without `sudo` access, install the required tools before running the workflow.

---

### 3️⃣ GitLab Personal Access Token

The GitLab token is used to:

- Validate GitLab project access
- Generate inventory
- Run migration readiness checks
- Check open merge requests
- Check running or pending pipelines
- Export GitLab projects and upload to intermediate storage
- Read branch and commit information for post-migration validation

Recommended scopes:

```text
read_api
api
```

The token must have access to all GitLab projects included in the inventory file.

---

### 4️⃣ GitHub Personal Access Token

The GitHub token is used to:

- Authenticate GitHub CLI
- Run repository migrations
- Validate migrated repositories
- Access target GitHub organizations

Recommended scopes:

```text
repo (full control)
workflow
admin:org (full control)
user (read access)
```

If the migration user is not a GitHub organization owner, a GitHub organization owner must grant the migrator role before migration.

If the target GitHub organization uses SAML SSO enforcement, authorize the GitHub PAT for the target organization before running migration.

---

### 5️⃣ Inventory Preparation

Generate the inventory using `gh gl2gh inventory-report`.

Example for all accessible projects:

```bash
gh gl2gh inventory-report --gitlab-server-url <GITLAB_SERVER_URL> --gitlab-pat <GITLAB_PAT>
```

Example for a specific GitLab group:

```bash
gh gl2gh inventory-report --gitlab-server-url <GITLAB_SERVER_URL> --gitlab-pat <GITLAB_PAT> --gitlab-group <GITLAB_GROUP>
```

This generates inventory files such as:

```text
groups.csv
projects.csv
```

---

### 6️⃣ Update `projects.csv`

Before running the workflow, update `projects.csv` with the following required columns:

| Column | Description |
|---|---|
| `github_org` | Target GitHub organization |
| `github_repo` | Target GitHub repository name |
| `gh_repo_visibility` | Repository visibility: `public`, `private`, or `internal` |

The workflow also validates that the inventory file contains the following required columns:

```text
group-path
project
url
github_org
github_repo
gh_repo_visibility
```

Upload or commit the updated inventory file to the GitHub repository where the workflow will run.

By default, the workflow expects:

```text
projects.csv
```

You can provide a different file name using the `Inventory file` workflow input.

---

### 7️⃣ GitHub Environment Setup

The workflow uses GitHub Environments to store migration secrets, variables, and approval rules.

Create a GitHub Environment to store migration configuration.

Example:

```text
gl2gh-migration-secrets
```

Navigate to:

```text
GitHub repository → Settings → Environments → New environment
```

### Required Secrets

| Secret | Description |
|---|---|
| `GITLAB_PAT` | GitLab Personal Access Token |
| `GH_PAT` | GitHub Personal Access Token |
| `AZURE_STORAGE_CONNECTION_STRING` | Required only when using Azure Storage |
| `AWS_ACCESS_KEY_ID` | Required only when using AWS Storage |
| `AWS_SECRET_ACCESS_KEY` | Required only when using AWS Storage |
| `AWS_SESSION_TOKEN` | Optional. Required only when using temporary AWS credentials |

### Variables

| Variable | Description |
|---|---|
| `GITLAB_SERVER_URL` | GitLab server URL. Defaults to `https://gitlab.com` if not configured |
| `TARGET_GITHUB_API_URL` | Required when using GitHub Enterprise Cloud with Data Residency. Example: https://api.SUBDOMAIN.ghe.com |
| `TARGET_UPLOAD_URL` | Required when using GitHub Enterprise Cloud with Data Residency and GitHub storage, the workflow automatically derives the upload URL from TARGET_GITHUB_API_URL if not configured |
| `STORAGE_TYPE` | Storage type. Supported values: `GITHUB`, `AZURE`, `AWS`. Defaults to `GITHUB` |
| `TARGET_UPLOAD_URL` | Optional. When using GitHub Enterprise Cloud with Data Residency and GitHub storage, the workflow automatically derives the upload URL from `TARGET_GITHUB_API_URL` if not configured |
| `AWS_BUCKET_NAME` | Required when using AWS storage |
| `AWS_REGION` | Required when using AWS storage |

---

### 8️⃣ Approval Environment Setup

Create a separate GitHub Environment for manual approval.

Example:

```text
gl2gh-migration-approvers
```

Configure required reviewers in this environment.

The approval stage is used only when the readiness check is enabled.

---

## 🚀 Executing GitHub Actions Pipeline

Before starting your first migration:

- ✅ Generate inventory using `gh gl2gh inventory-report`
- ✅ Update repository mappings in `projects.csv`
- ✅ Commit the inventory file to the workflow repository
- ✅ Configure GitHub Environment secrets and variables
- ✅ Configure PAT permissions
- ✅ Verify storage configuration

---

### Step 1 - Generate Inventory and Update Inventory

Generate the inventory and update repository mappings as described in:

- 5️⃣ Inventory Preparation
- 6️⃣ Update `projects.csv`

- [5️⃣ Inventory Preparation](#5️⃣ Inventory Preparation)
- [6️⃣ Update `projects.csv`](#6️⃣ Update `projects.csv)

---

### Step 2 - Commit Inventory File

Commit the updated inventory file to the repository containing this workflow.

```bash
git add projects.csv
git commit -m "Configure GL2GH migration inventory"
git push
```

---

### Step 4 - Configure GitHub Environment

Create the migration environment and configure required secrets and variables.

Default environment name:

```text
gl2gh-migration-secrets
```

Required secrets:

```text
GITLAB_PAT
GH_PAT
```

Optional storage-related secrets and variables depend on the selected storage type.

---

### Step 5 - Configure Approval Environment

Create the approval environment and configure required reviewers.

Default approval environment name:

```text
gl2gh-migration-approvers
```

---

### Step 6 - Run the Workflow

Navigate to:

```text
Actions → GitLab to GitHub Migration Pipeline
```

Select:

```text
Run workflow
```

Review the workflow inputs if customization is required. Default values are provided for all workflow inputs.

| Input | Description |
|---|---|
| `Environment name` | GitHub Environment containing migration secrets and variables. Default: `gl2gh-migration-secrets` |
| `Inventory file` | Inventory CSV file name. Default: `projects.csv` |
| `Approval Environment name` | GitHub Environment used for manual approval. Default: `gl2gh-migration-approvers` |
| `Use Self-Hosted Runner` | Set to `true` to use a self-hosted runner. Default: `false` |
| `Self-Hosted Runner Label` | Runner label to use when self-hosted runner is enabled |
| `Run migration readiness check` | Set to `true` to run readiness check and approval before migration. Default: `true` |

---

### Step 7 - Review Readiness Results

If readiness is enabled, review:

- Open merge requests
- Running pipelines
- Pending pipelines
- Skipped rows, if any

Approve migration if results are acceptable.

---

### Step 8 - Review Migration Results

Review the migration summary and artifact:

```text
output_files/migration/repos_with_status.csv
```

---

### Step 9 - Review Validation Results

Review validation reports:

```text
output_files/post_migration_validation/
```

---

### 📊 GitHub Actions Job Summaries

The workflow publishes GitHub Actions job summaries for easier review.

### Readiness Summary

Includes:

- Total rows processed
- Skipped rows
- Open merge request count
- Running or pending pipeline count
- Detailed findings when the count is small
- Readiness artifact reference for full details

If open merge requests or running/pending pipelines exceed the configured display threshold, only summary counts are displayed and the workflow directs users to readiness artifacts.

### Migration Summary

Includes:

- Successful migration count
- Failed migration count
- Per-repository migration status

### Post-Migration Validation Summary

Includes:

- Repository existence status
- Branch count status
- Default branch status
- Commit count status
- SHA validation status

---

## 📁 Artifact Locations

The workflow uploads logs and outputs as artifacts.

### Logs

```text
logs/
├── 1_migration_readiness_check/
├── 2_migration/
└── 3_post_migration_validation/
```

Repository-specific migration logs are stored under:

```text
logs/2_migration/repository-migration-logs/
```

### Output Files

```text
output_files/
├── migration/
└── post_migration_validation/
```

Important files:

```text
output_files/migration/repos_with_status.csv
output_files/post_migration_validation/validation-summary_<timestamp>.csv
output_files/post_migration_validation/validation-summary_<timestamp>.md
```

### 🎉 Migration Complete

After migration completes:

- Review GitHub Actions job summaries
- Download artifacts for audit or troubleshooting
- Ask repository owners to perform manual validation
- Complete mannequin reclamation if required

---

## 🧑‍🤝‍🧑 Mannequin Reclamation

If GitLab users are migrated as mannequins, generate and update the mannequin CSV after migration.

### GitHub Enterprise Cloud

```bash
gh gl2gh generate-mannequin-csv --github-org "<github-org>"
```

```bash
gh gl2gh reclaim-mannequin --github-org "<github-org>" --csv mannequins.csv --skip-invitation
```

### GitHub Enterprise Cloud with Data Residency

```bash
gh gl2gh generate-mannequin-csv --github-org "<github-org>" --target-api-url https://api.SUBDOMAIN.ghe.com
```

```bash
gh gl2gh reclaim-mannequin --github-org "<github-org>" --csv mannequins.csv --skip-invitation --target-api-url https://api.SUBDOMAIN.ghe.com
```

---

## ❓ Frequently Asked Questions

### Q1: Can multiple teams run this workflow simultaneously?

**A:** Yes, if they are migrating different repositories.

Best practices:

- Coordinate migration schedules across teams
- Use separate inventory files per team
- Ensure each repository appears in only one workflow run
- If uncertain, run migrations sequentially

---

### Q2: Can I skip the readiness check?

**A:** Yes. Set `Run migration readiness check=false`.

When readiness is skipped:

- Migration readiness check is skipped
- Approval stage is skipped
- Repository migration starts after environment validation
- Post-migration validation runs automatically after migration

---

### Q3: Can I run post-migration validation without migration?

**A:** No. In this workflow, migration and post-migration validation run together.

Post-migration validation depends on:

```text
output_files/migration/repos_with_status.csv
```

generated by the migration stage.

---

### Q4: What happens if some repositories fail migration?

**A:** The workflow tracks successful and failed repositories in:

```text
output_files/migration/repos_with_status.csv
```

Post-migration validation runs after the migration job succeeds. Review the migration summary and artifacts for repository-level status.

---

### Q5: What storage options are supported?

**A:** The workflow supports:

```text
GITHUB
AZURE
AWS
```

If `STORAGE_TYPE` is not configured, the workflow defaults to:

```text
GITHUB
```

---

### Q6: Do I need to configure `TARGET_UPLOAD_URL` for GitHub Enterprise Cloud with Data Residency?

**A:** No, If it is not configured, the workflow derives it from `TARGET_GITHUB_API_URL`.

Example:

```text
TARGET_GITHUB_API_URL=https://api.contoso.ghe.com
```

Automatically derives:

```text
https://uploads.contoso.ghe.com
```

If `TARGET_UPLOAD_URL` is configured, the workflow uses the configured value.

---

### Q7: Can I use a self-hosted runner?

**A:** Yes.

Set:

```text
Use Self-Hosted Runner=true
Self-Hosted Runner Label=<runner-label>
```

---

### Q8: How long does migration take?

**A:** Migration time depends on repository size, number of repositories, storage backend, and GitHub Enterprise Importer processing time.

For large migration batches, use a self-hosted runner.

---

### Q9: Does this workflow delete or modify GitLab repositories?

**A:** No. The migration copies repository data from GitLab to GitHub. GitLab repositories are not deleted by this workflow.

---

### Q10: Where do I find logs and reports?

**A:** Logs and reports are available in GitHub Actions artifacts and under:

```text
logs/
output_files/
```

---

## 🛠️ Troubleshooting

### Authentication Issues

Verify:

- GitLab token is valid
- GitHub token has required scopes
- GitHub token is SSO-authorized for the target organization
- GitHub CLI is authenticated to the correct host

```bash
gh auth status
```

For Data Residency:

```bash
gh auth status --hostname SUBDOMAIN.ghe.com
```

---

### Inventory File Not Found

Verify:

- The inventory file exists in the repository
- The workflow input `INVENTORY_FILE` matches the file name
- The inventory file is not empty

---

### Required Inventory Columns Missing

The inventory file must contain:

```text
group-path
project
url
github_org
github_repo
gh_repo_visibility
```

---

### Target Repository Already Exists

If migration fails because the target repository already exists:

- Use a different target repository name
- Archive the existing repository
- Delete the existing repository only if approved

---

### Post-Migration Validation Failure

Check:

```text
output_files/migration/repos_with_status.csv
output_files/post_migration_validation/
logs/3_post_migration_validation/
```

Validation depends on repositories that migrated successfully.

---

### Migration Did Not Reach SUCCEEDED State

Review the repository-specific migration log under:

```text
logs/2_migration/repository-migration-logs/
```

Also review:

```text
output_files/migration/repos_with_status.csv
```

---

### Cancel Migration

Use the migration ID if an active migration must be aborted.

```bash
gh gl2gh abort-migration --migration-id "<migration-id>"
```

For Data Residency:

```bash
gh gl2gh abort-migration --migration-id "<migration-id>" --target-api-url https://api.SUBDOMAIN.ghe.com
```

---

## ✅ Developer Verification Checklist

After migration, repository owners should verify:

- Repository is accessible in GitHub
- Branches are present
- Commit history is available
- Files and folders are present
- Default branch is correct
- Users can clone, pull, and push as expected
- Pull requests can be created
- Branch protection and repository permissions are correct
- Required workflows and integrations are updated

Example:

```bash
git clone https://github.com/<org>/<repo>.git
cd <repo>
git checkout -b test-migration-verification
echo "Migration test" >> test-file.txt
git add test-file.txt
git commit -m "Test commit post-migration"
git push origin test-migration-verification
```

---
