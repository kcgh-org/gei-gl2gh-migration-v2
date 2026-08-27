# 🚀 Quick Start: Your First Migration

## Generate PAT Tokens

GitLab PAT token recommended scopes:

```text
read_api
api
```

GitHub PAT token recommended scopes:

```text
repo (full control)
workflow
admin:org (full control)
user (read access)
```
> Note:
> If the migration user is not a GitHub organization owner, a GitHub organization owner must grant the migrator role before migration.

## Workflow configuration and execution

### Step 1 - Generate and Update Inventory
 - Generate inventory:
```bash
gh gl2gh inventory-report --gitlab-server-url <GITLAB_SERVER_URL> --gitlab-pat <GITLAB_PAT>
```
 - Update `projects.csv` with the following required columns:
   
| Column | Description |
|---|---|
| `github_org` | Target GitHub organization |
| `github_repo` | Target GitHub repository name |
| `gh_repo_visibility` | Repository visibility: `public`, `private`, or `internal` |

### Step 2 - Create a GitHub Repository
 - Create a GitHub repository to host the migration workflow.
Example:
```text
gl2gh-migration-pipeline
```

### Step 3 - Upload scripts, pipeline files and projects.csv
 - Upload the following content to the repository:
```text
.github/
1_migration_readiness_check.sh
2_migration.sh
3_post_migration_validation.sh
projects.csv
```

### Step 4 - Create GitHub Environments
 - Create two GitHub Environments:
```text
gl2gh-migration-approvers
gl2gh-migration-secrets
```

Configure required reviewers in the `gl2gh-migration-approvers` environment.

---

### Step 5 - Configure secrets and variables
 - Create following secrets in gl2gh-migration-secrets
   
| Secret | Description |
|---|---|
| `GITLAB_PAT` | GitLab Personal Access Token |
| `GH_PAT` | GitHub Personal Access Token |
| `AZURE_STORAGE_CONNECTION_STRING` | Required only when using Azure Storage |
| `AWS_ACCESS_KEY_ID` | Required only when using AWS Storage |
| `AWS_SECRET_ACCESS_KEY` | Required only when using AWS Storage |
| `AWS_SESSION_TOKEN` | Optional. Required only when using temporary AWS credentials |
 
 - Create following variables in gl2gh-migration-secrets
   
| Variable | Description |
|---|---|
| `GITLAB_SERVER_URL` | GitLab server URL. Defaults to `https://gitlab.com` if not configured |
| `TARGET_GITHUB_API_URL` | Required when using GitHub Enterprise Cloud with Data Residency. Example: https://api.SUBDOMAIN.ghe.com |
| `STORAGE_TYPE` | Storage type. Supported values: `GITHUB`, `AZURE`, `AWS`. Defaults to `GITHUB` |
| `TARGET_UPLOAD_URL` | Required when using GitHub Enterprise Cloud with Data Residency and GitHub storage, the workflow automatically derives the upload URL from TARGET_GITHUB_API_URL if not configured |
| `AWS_BUCKET_NAME` | Required when using AWS storage |
| `AWS_REGION` | Required when using AWS storage |

### Step 6 - Run the Workflow
 - Navigate to:
```text
Actions → GitLab to GitHub Migration Pipeline
```

 - Select:
```text
Run workflow
```

 - Review and update workflow inputs only if customization is required. Default values are provided for all inputs:

| Input | Description |
|---|---|
| `Environment with Secrets and Variables` | GitHub Environment containing migration secrets and variables. Default: `gl2gh-migration-secrets` |
| `Inventory CSV file` | Inventory CSV file name. Default: `projects.csv` |
| `Approval environment` | GitHub Environment used for manual approval. Default: `gl2gh-migration-approvers` |
| `Use Self-Hosted Runner` | Set to `true` to use a self-hosted runner. Default: `false` |
| `Self-Hosted Runner Label` | Runner label to use when self-hosted runner is enabled |
| `Run migration readiness check` | Set to `true` to run readiness check and approval before migration. Default: `true` |

---

## 🎉 Migration Complete

Review:

```text
output_files/migration/repos_with_status.csv
output_files/post_migration_validation/
```

Download workflow artifacts and complete developer validation before decommissioning the GitLab repository.
