# Fellwork repos managed by bootstrap.
# Adding/removing a repo here is the only way to change what bootstrap clones.
# Outliers (experiments, archived, personal) are intentionally not auto-pulled.

@{
    repos = @(
        @{
            name        = 'api'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Rust/Axum backend (Fly.io deploy target)'
            structureCheck = @('Cargo.toml', 'apps/api/Cargo.toml')
            envExamples = @('apps/api/.env.example')
        }
        @{
            name        = 'web'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Nuxt frontend (Cloudflare Pages)'
            structureCheck = @('package.json', 'apps/web/package.json')
            envExamples = @('apps/web/.env.example')
        }
        @{
            name        = 'ops'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Dev tooling + wiki'
            structureCheck = @('package.json')
            envExamples = @()
        }
        @{
            name        = 'lint'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Shared linting config'
            structureCheck = @()
            envExamples = @()
        }
        @{
            name        = 'scribe'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Reactive DOM Vue/Nuxt with AI as first-class consumer'
            structureCheck = @('package.json')
            envExamples = @()
        }
        @{
            name        = 'shared-configs'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Shared config files'
            structureCheck = @()
            envExamples = @()
        }
        @{
            name        = 'tsconfig'
            org         = 'fellwork'
            branch      = 'main'
            description = 'Shared TypeScript config'
            structureCheck = @()
            envExamples = @()
        }
    )
}
