# AWS Cloud Security Lab

## Descripción

**AWS Cloud Security Lab** es un proyecto práctico enfocado en aprender y demostrar conceptos básicos de **Cloud Security utilizando Amazon Web Services (AWS)**.

La idea es construir una infraestructura pequeña y controlada en AWS y, a partir de ella, revisar diferentes aspectos de seguridad: acceso al servidor, exposición de puertos, permisos, autenticación, monitoreo y auditoría.

El proyecto también servirá como base para crear contenido educativo y compartir lo aprendido de forma sencilla, utilizando ejemplos, diagramas y capturas de pantalla.

---

## Objetivo

Crear un laboratorio práctico que permita comprender cómo aplicar principios básicos de seguridad desde el momento en que se despliega una infraestructura en la nube.

El proyecto se desarrollará progresivamente, documentando cada etapa y las decisiones de seguridad tomadas.

---

## Arquitectura propuesta

```text
                    AWS CLOUD
                       │
                       ▼
                ┌─────────────┐
                │    EC2      │
                │   Servidor  │
                └──────┬──────┘
                       │
                       ▼
              ┌─────────────────┐
              │ Security Group  │
              │ Puertos /       │
              │ Protocolos /    │
              │ Orígenes        │
              └─────────────────┘

                       │
                       ▼
                 ┌───────────┐
                 │    IAM    │
                 │ Usuarios  │
                 │ Roles     │
                 │ Permisos  │
                 └───────────┘
                       │
              ┌────────┴────────┐
              ▼                 ▼
        ┌───────────┐     ┌───────────┐
        │ CloudWatch│     │ CloudTrail│
        │ Monitoreo │     │ Auditoría │
        └───────────┘     └───────────┘
```

---

## Tecnologías

* **Amazon EC2** — infraestructura y servidor.
* **Security Groups** — control del tráfico de red.
* **AWS IAM** — gestión de identidades, roles y permisos.
* **MFA** — protección adicional para las cuentas.
* **Amazon CloudWatch** — monitoreo y observabilidad.
* **AWS CloudTrail** — registro y auditoría de actividades.
* **GitHub** — código y documentación.
* **Markdown** — documentación técnica.

---

## Presupuesto

El proyecto busca mantenerse con un **presupuesto bajo**, utilizando recursos gratuitos o de bajo costo cuando estén disponibles y sean adecuados para el laboratorio.

Los recursos que no sean necesarios serán detenidos o eliminados para evitar costos innecesarios.

> El costo real dependerá de los recursos utilizados, la región y el tiempo durante el cual permanezcan activos.

---

## Valor que entregará

El principal valor del proyecto será convertir conceptos de **Cloud Security** en ejemplos prácticos y fáciles de entender.

La documentación permitirá mostrar:

* Cómo revisar una instancia EC2.
* Cómo analizar un Security Group.
* Cómo identificar qué puertos y servicios están expuestos.
* Cómo revisar usuarios, roles y permisos mediante IAM.
* Cómo aplicar el principio de mínimo privilegio.
* Cómo utilizar MFA como capa adicional de protección.
* Cómo comenzar a monitorear una infraestructura.
* Cómo registrar y revisar actividades mediante auditoría.

Además, cada etapa podrá convertirse en contenido educativo para otras personas que estén comenzando en AWS y Cloud Security.

---

## Roadmap

### Fase 1 — Infraestructura

* Crear o utilizar una instancia EC2.
* Documentar la configuración inicial.

### Fase 2 — Seguridad de red

* Revisar Security Groups.
* Analizar puertos, protocolos y orígenes.
* Aplicar configuraciones necesarias.

### Fase 3 — Identidad y acceso

* Revisar IAM.
* Analizar usuarios, roles y permisos.
* Aplicar principio de mínimo privilegio.
* Configurar MFA cuando corresponda.

### Fase 4 — Monitoreo y auditoría

* Explorar CloudWatch.
* Explorar CloudTrail.
* Documentar eventos relevantes.

### Fase 5 — Documentación y contenido

* Crear diagramas.
* Añadir capturas de pantalla.
* Documentar aprendizajes.
* Compartir contenido técnico.

---

## Estructura propuesta

```text
aws-cloud-security-lab/
│
├── README.md
│
├── 01-EC2/
├── 02-Security-Groups/
├── 03-IAM/
├── 04-MFA/
├── 05-CloudWatch/
└── 06-CloudTrail/
```

---

## Resultado esperado

Al finalizar el proyecto se contará con un laboratorio documentado que permita demostrar, de manera práctica, cómo revisar y mejorar aspectos básicos de seguridad en una infraestructura desplegada en AWS.

El objetivo no es solamente construir un servidor, sino **aprender a considerar la seguridad durante todo el proceso de despliegue y operación de una infraestructura cloud**.
