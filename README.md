# Repository Manager para iOS

App de iPhone para **subir muchos secretos de GitHub a uno o varios repositorios de una vez**.

Es la versión iOS de [Mac-Github-Repository-Manager-by-Leonera](https://github.com/leonardoramirezr/Mac-Github-Repository-Manager-by-Leonera): mismas funciones, interfaz rediseñada al estilo de iOS y, a diferencia de la versión de Mac, **cada preset puede aplicarse a varios repositorios a la vez**.

SwiftUI, iOS 17 o posterior y **ninguna dependencia de terceros** (el proyecto de Xcode se genera con [XcodeGen](https://github.com/yonaskolb/XcodeGen), solo una herramienta de build).

> La interfaz está en español.

## Funciones

- **Primera configuración**: token de acceso personal (fine-grained o clásico), URL del servidor (github.com o GitHub Enterprise Server) y, opcionalmente, una cuenta u organización (nombre o URL, p. ej. `https://github.com/mi-org`) para filtrar la lista de repositorios. El token se valida contra la API antes de guardarlo.
- **Presets** (pestaña *Presets*): crear, renombrar, duplicar (deslizar o mantener pulsado) y eliminar. Cada preset tiene:
  - los secretos (nombre + valor, ocultos por defecto, con valores multilínea y botón de pegar),
  - **uno o más repositorios de destino**: lista con búsqueda y selección múltiple de los repositorios que ve el token, «seleccionar todos» y opción de escribir `propietario/repositorio` a mano,
  - el tipo de secreto: **Actions**, **Dependabot**, **Codespaces** o un **entorno** de Actions (se crea en cada repositorio si no existe),
  - opcionalmente, **ajustes de pull requests** que se aplican a todos sus repositorios: quién puede crear pull requests (**todos los usuarios** o **solo colaboradores**) y **Allow merge commits**, **Allow squash merging** y **Allow rebase merging** (al menos uno activado),
  - opcionalmente, el origen de **GitHub Pages › Build and deployment**: **desde una rama** (rama, vacía = la rama por defecto de cada repositorio, y carpeta `/` o `/docs`) o **GitHub Actions**; si la rama no existe, se crea desde el último commit de `main` (o de la rama por defecto si no hay `main`); si Pages no está activado, se activa.

  Un preset puede tener solo secretos, solo ajustes o ambos.
- **Importar `.env`**: pegar líneas `CLAVE=valor` o abrir un archivo desde Archivos; los secretos existentes se actualizan.
- **Validación** de nombres según las reglas de GitHub (letras, números y `_`, sin empezar por número ni por `GITHUB_`, sin duplicados).
- **Ajustes de un repositorio** (pestaña *Repositorios*): consultar y cambiar, para un solo repositorio, quién puede crear pull requests (**todos los usuarios** o **solo colaboradores**), los métodos de merge permitidos (**merge commits**, **squash merging** y **rebase merging**, al menos uno activado) y el origen de **GitHub Pages › Build and deployment**: **desde una rama** (rama y carpeta `/` o `/docs`; si la rama no existe, se crea desde el último commit de `main`) o **GitHub Actions**. Si Pages no está activado, se activa con el origen elegido. Desde la misma pantalla, **Commit vacío** crea un commit sin cambios en la rama que elijas (con el mensaje que quieras), por ejemplo para volver a lanzar sus workflows.
- **Pull de main** (pestaña *Repositorios*, dentro de un repositorio): eliges una rama y la app comprueba si traer los cambios de `main` daría conflictos. Sin conflictos aparece el botón **Pull de main**, que hace un merge en GitHub; con conflictos, el botón queda desactivado y se listan los archivos. GitHub no ofrece una simulación de merge, así que la comprobación se hace en el iPhone con las reglas de `git merge` (por archivo y por líneas). Limitaciones: no detecta renombrados (un archivo renombrado en una rama y editado en la otra aparece como conflicto), y en líneas repetidas ambiguas (p. ej. llaves o líneas vacías) puede no coincidir con git. Si la comprobación da «sin conflictos» pero GitHub rechaza el merge, la rama no cambia.
- **Aplicar** el preset a todos los repositorios seleccionados (varios en paralelo) con progreso por repositorio, por ajuste y por secreto, resumen de creados/actualizados/fallidos y botón para **reintentar solo los repositorios que fallaron**.

## Seguridad

- El token **y los presets (con los valores de los secretos)** se guardan en el Llavero de iOS con `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (no se sincronizan con iCloud ni pasan a otro dispositivo). En `UserDefaults` solo van los ajustes no sensibles (servidor, cuenta, login).
- Los valores se cifran en el iPhone con un *sealed box* compatible con libsodium (`crypto_box_seal`: X25519 + XSalsa20-Poly1305) usando la clave pública de cada repositorio, como [exige GitHub](https://docs.github.com/en/rest/guides/encrypting-secrets-for-the-rest-api). X25519 viene de CryptoKit; XSalsa20, Poly1305 y BLAKE2b están en `RepositoryManager/Services/SealedBox.swift` y se comprueban con vectores de libsodium (`make test`).
- El token solo se envía al host de la API configurado.

## Permisos del token

| Tipo de token | Permisos necesarios |
|---------------|---------------------|
| Fine-grained  | Acceso a los repositorios de destino, **Secrets: Read and write** (y **Dependabot secrets**, **Codespaces secrets** o **Environments: Read and write** si usas esos tipos). Para los ajustes de repositorio (presets o pestaña *Repositorios*), **Administration: Read and write** y **Pages: Read and write** (más **Contents: Read and write** para crear la rama de Pages si no existe, crear commits vacíos o hacer pull de main). *Metadata: Read* se incluye automáticamente. |
| Clásico       | Scope `repo` (`public_repo` basta solo para repositorios públicos). |

Los ajustes de repositorio requieren además que tu usuario sea **administrador** del repositorio.

## Instalar en el iPhone (Ad Hoc desde GitHub Pages)

Cada push compila la app en GitHub Actions (`.github/workflows/build.yml`), la firma **Ad Hoc** y publica el IPA en GitHub Pages, desde donde se instala con Safari en cualquier iPhone registrado.

### 1. Secrets del repositorio

En **Settings › Secrets and variables › Actions** del repositorio (secrets del repositorio, no de una organización si el repo es personal):

| Secret | Contenido |
|--------|-----------|
| `ASC_KEY_ID` | ID de la clave de la API de App Store Connect. |
| `ASC_ISSUER_ID` | Issuer ID de App Store Connect (Users and Access › Integrations). |
| `ASC_KEY_P8` | Contenido del archivo `AuthKey_XXXX.p8` (texto PEM; también se acepta en base64). Debe ser una **Team Key con rol Admin**, necesaria para el certificado de distribución gestionado en la nube. |
| `APPLE_TEAM_ID` | Team ID del programa Apple Developer. |

- **Sin ninguno de los cuatro**, el workflow genera un IPA **sin firmar** (artefacto y release, pero no instalable ni publicado en Pages).
- **Con solo algunos**, el workflow falla con un error que indica cuáles faltan.

El bundle ID es siempre `com.leonardoramirezr.repo-manager-by-leonera` y no se puede sustituir.

### 2. Activar GitHub Pages

**Después del primer build firmado** (que crea la rama `gh-pages`), ve a **Settings › Pages**, elige *Deploy from a branch*, la rama **`gh-pages`** y la carpeta **`/ (root)`**. La web queda en `https://leonardoramirezr.github.io/iOS-Github-Repository-Manager-by-Leonera/`.

### 3. Instalar

Abre en **Safari** del iPhone el enlace que aparece en el resumen de la ejecución, en las notas de la release o en la portada de GitHub Pages, y pulsa **Instalar**. En iOS 16 o posterior, activa **Ajustes › Privacidad y seguridad › Modo de desarrollador** la primera vez para poder abrir apps Ad Hoc.

### Añadir un iPhone

Basta con **registrar su UDID** en [Certificates, Identifiers & Profiles › Devices](https://developer.apple.com/account/resources/devices/list) y **hacer push**: cada build regenera el perfil Ad Hoc con todos los dispositivos registrados.

### Qué hace el workflow

1. **Etiqueta y release**: en `main`, la etiqueta es `0.x.0` (el número intermedio sube respecto al último tag) y se publica como release estable *Latest*; en otras ramas, `build-<run_number>-<sha7>` como pre-release. Ningún build se cancela (`concurrency` por `main` o por `run_id`).
2. **Identificadores**: el bundle ID es fijo, `com.leonardoramirezr.repo-manager-by-leonera`, definido en `APP_BUNDLE_ID` y usado en `PRODUCT_BUNDLE_IDENTIFIER` (`project.yml`); el workflow no lo sustituye. La app no usa App Groups ni capacidades que Xcode no pueda registrar solo con la clave de API.
3. **Validación previa** con la API de App Store Connect (`scripts/asc.py`, solo biblioteca estándar de Python + `openssl` para el JWT ES256): comprueba que la clave funciona y que hay al menos un dispositivo iOS registrado.
4. **Archive** con firma automática (`-allowProvisioningUpdates` y la clave de API): Xcode registra el App ID y crea los perfiles.
5. **Exportación Ad Hoc** (`method=release-testing`, `signingStyle=automatic`) con el certificado de distribución gestionado en la nube; después verifica que cada bundle lleva un `embedded.mobileprovision` Ad Hoc y muestra cuántos dispositivos incluye.
6. **Revoca** el certificado «Apple Development» temporal que `xcodebuild` crea en cada ejecución (solo los que no estaban antes en el llavero), aunque el build falle.
7. **Publica en GitHub Pages** (`scripts/publish-pages.sh`): una carpeta por etiqueta con el IPA, `manifest.plist`, `index.html` con el botón `itms-services://` y `build.json`; la portada lista todos los builds y enlaza la última versión estable. La rama `gh-pages` se reescribe como un único commit huérfano (los IPA no se acumulan en el historial) y conserva todas las versiones de `main` y los últimos 50 builds de otras ramas.

## Desarrollo local

Requiere macOS con Xcode 16 y XcodeGen (`brew install xcodegen`).

```sh
make project   # genera RepositoryManager.xcodeproj desde project.yml
make open      # lo genera y lo abre en Xcode
make test      # tests de cifrado y de comprobación de conflictos
```

Para ejecutarla en un dispositivo desde Xcode, elige tu equipo en *Signing & Capabilities* (o pasa `DEVELOPMENT_TEAM`).

## Estructura

```
.
├── project.yml                         # Proyecto XcodeGen (el .xcodeproj no se versiona)
├── RepositoryManager/
│   ├── App/
│   │   ├── RepositoryManagerApp.swift  # Punto de entrada y vista raíz
│   │   └── AppState.swift              # Estado: conexión, presets, aplicación a varios repositorios
│   ├── Model/Models.swift              # SecretSet, SecretItem, ajustes, .env, validación
│   ├── Services/
│   │   ├── GitHubClient.swift          # Cliente de la API REST de GitHub
│   │   ├── MergeCheck.swift            # Comprobación de conflictos con main (reglas de git merge)
│   │   ├── SealedBox.swift             # Sealed box compatible con libsodium
│   │   └── KeychainStore.swift         # Persistencia en el Llavero
│   ├── Views/
│   │   ├── SetsListView.swift          # Lista de presets
│   │   ├── SecretSetDetailView.swift   # Editor del preset y barra para aplicarlo
│   │   ├── SecretEditorViews.swift     # Editor de secreto e importación .env
│   │   ├── RepositorySelectionView.swift # Selección múltiple de repositorios
│   │   ├── UploadView.swift            # Progreso y resultados del envío
│   │   ├── RepositorySettingsView.swift # Pestaña Repositorios: pull requests y GitHub Pages
│   │   ├── EmptyCommitView.swift       # Commit vacío en una rama
│   │   ├── PullMainView.swift          # Pull de main tras comprobar conflictos
│   │   └── ConnectionViews.swift       # Bienvenida y Ajustes
│   └── Resources/Assets.xcassets       # Icono y color de acento
├── tests/SealedBoxTests.swift          # Vectores de prueba del cifrado
├── tests/MergeCheckTests.swift         # Casos de conflicto verificados con git
├── scripts/
│   ├── asc.py                          # API de App Store Connect (validación y revocación)
│   ├── publish-pages.sh                # Publicación en la rama gh-pages
│   └── pages.py                        # Genera manifest.plist, index.html y build.json
└── .github/workflows/build.yml
```

## Licencia

Este proyecto se distribuye bajo la [GNU General Public License v3.0](LICENSE).
