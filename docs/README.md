# Documentación técnica

Documentación **del proyecto** (para quien desarrolla o mantiene la aplicación). La
documentación **de uso**, pensada para el piloto, está dentro de la aplicación en
`/docs` (menú *Documentación*) y se escribe en `lib/eth_web/docs_pages/`.

| Documento | Qué contiene |
|---|---|
| [arquitectura.md](arquitectura.md) | Vista general, árbol de supervisión, flujo de datos, tablas ETS, tópicos PubSub, base de datos y capa web. |
| [motor.md](motor.md) | Cómo se evalúa el mercado y cómo se personaliza cada consulta: etapas, familias, versionado y dónde vive cada fórmula. |
| [desarrollo.md](desarrollo.md) | Entorno, comandos, tests, modo Replay, depuración y recetas para los cambios más comunes. |
| [ERS.md](ERS.md) | Especificación de requisitos: la fuente de verdad funcional (RF/RNF, fórmulas en §8, decisiones D-xx). |
| [audit-v1.0.md](audit-v1.0.md) | Auditoría previa a v1.0: rendimiento, seguridad, calidad y los hallazgos con su estado. |

Otros archivos útiles en la raíz del repositorio:

- [`README.md`](../README.md): instalación y uso para el piloto.
- [`CLAUDE.md`](../CLAUDE.md): reglas del proyecto (autoría de git, idioma, ESI, tests),
  comandos y convenciones de código. Vale para personas y para asistentes.
- [`CHANGELOG.md`](../CHANGELOG.md): cambios por versión.

## Cómo se mantiene

- Un cambio de requisito se documenta en el ERS en el mismo commit.
- Un cambio de arquitectura (un proceso, una tabla ETS, un tópico nuevo) se refleja en
  [arquitectura.md](arquitectura.md).
- Todo lo que ve el piloto (una sigla, un parámetro, una pantalla) se explica en la
  documentación de la aplicación y, si es un término, en el glosario
  (`EthWeb.Glossary`).
