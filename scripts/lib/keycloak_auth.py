#!/usr/bin/env python3
"""Módulo de autenticación contra Keycloak con auto-renovación de token.

Permite obtener tokens JWT de Keycloak utilizando:
  - Password Grant (grant_type=password)
  - Client Credentials Grant (grant_type=client_credentials)

Garantiza renovación transparente del token durante ejecuciones largas
antes de que caduque el access_token (TTL / expires_in).
"""

import json
import logging
import os
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

# Configuración por defecto de logging
logger = logging.getLogger("keycloak_auth")


class KeycloakAuthError(Exception):
    """Excepción para errores de autenticación con Keycloak."""

    pass


class KeycloakAuthenticator:
    """Gestiona la obtención y renovación automática de tokens en Keycloak."""

    def __init__(
        self,
        keycloak_url=None,
        realm=None,
        grant_type="password",
        client_id=None,
        client_secret=None,
        username=None,
        password=None,
        margin_seconds=60,
        timeout=10,
    ):
        """Inicializa el autenticador con valores explícitos o variables de entorno.

        Args:
            keycloak_url: Base URL de Keycloak (ej. http://localhost:8180)
            realm: Nombre del Realm de Keycloak (ej. parking)
            grant_type: Tipo de grant ('password' o 'client_credentials')
            client_id: ID del cliente Keycloak
            client_secret: Secreto del cliente (requerido en client_credentials)
            username: Nombre de usuario (requerido en password grant)
            password: Contraseña de usuario (requerido en password grant)
            margin_seconds: Margen en segundos antes del tiempo de expiración para renovar
            timeout: Timeout en segundos para las peticiones HTTP
        """
        self.keycloak_url = (
            keycloak_url
            or os.environ.get("KEYCLOAK_URL")
            or "http://localhost:8180"
        ).rstrip("/")
        self.realm = (
            realm or os.environ.get("KEYCLOAK_REALM") or "parking"
        )
        self.grant_type = grant_type.lower()

        if self.grant_type not in ("password", "client_credentials"):
            raise ValueError(
                f"grant_type invalido: '{grant_type}'. Usar 'password' o 'client_credentials'."
            )

        # Asignar defaults según grant_type si no se especificaron
        if self.grant_type == "client_credentials":
            self.client_id = (
                client_id
                or os.environ.get("STAY_CLIENT_ID")
                or os.environ.get("KEYCLOAK_CLIENT")
                or "parking-stay-service"
            )
            self.client_secret = (
                client_secret
                or os.environ.get("STAY_CLIENT_SECRET")
                or os.environ.get("KEYCLOAK_CLIENT_SECRET")
                or "stay-service-dev-secret-no-usar-fuera-de-local"
            )
            self.username = None
            self.password = None
        else:
            # password grant
            self.client_id = (
                client_id
                or os.environ.get("KEYCLOAK_CLIENT")
                or "parking-frontend"
            )
            self.client_secret = client_secret or os.environ.get(
                "KEYCLOAK_CLIENT_SECRET"
            )
            self.username = (
                username
                or os.environ.get("DEMO_USER")
                or os.environ.get("KEYCLOAK_USER")
                or "admin.test"
            )
            self.password = (
                password
                or os.environ.get("DEMO_PASSWORD")
                or os.environ.get("KEYCLOAK_PASSWORD")
                or "Admin.123!"
            )

        self.margin_seconds = margin_seconds
        self.timeout = timeout

        # Estado del token en memoria
        self._token = None
        self._refresh_token = None
        self._token_at = 0
        self._token_ttl = 0
        self._expires_in = 0

    @property
    def token_endpoint(self):
        """URL del endpoint de emisión de tokens OIDC de Keycloak."""
        return f"{self.keycloak_url}/realms/{self.realm}/protocol/openid-connect/token"

    def fetch_token(self):
        """Pide un nuevo access_token a Keycloak y calcula la ventana de renovación.

        Returns:
            str: El access_token obtenido.

        Raises:
            KeycloakAuthError: Si no se puede contactar con Keycloak o las credenciales fallan.
        """
        payload = {"grant_type": self.grant_type, "client_id": self.client_id}

        if self.grant_type == "client_credentials":
            if not self.client_secret:
                raise KeycloakAuthError(
                    "Falta client_secret para client_credentials grant."
                )
            payload["client_secret"] = self.client_secret
        elif self.grant_type == "password":
            if not self.username or not self.password:
                raise KeycloakAuthError(
                    "Falta username o password para password grant."
                )
            payload["username"] = self.username
            payload["password"] = self.password
            if self.client_secret:
                payload["client_secret"] = self.client_secret

        data = urlencode(payload).encode("utf-8")
        headers = {
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        }

        req = Request(self.token_endpoint, data=data, headers=headers, method="POST")

        logger.info(
            "Conectando a Keycloak para solicitar token (endpoint=%s, grant=%s, client=%s)...",
            self.token_endpoint,
            self.grant_type,
            self.client_id,
        )

        try:
            with urlopen(req, timeout=self.timeout) as resp:
                raw_body = resp.read().decode("utf-8")
                token_data = json.loads(raw_body)
        except HTTPError as e:
            error_body = ""
            try:
                error_body = e.read().decode("utf-8")
            except Exception:
                pass
            msg = (
                f"Fallo HTTP {e.code} obteniendo token de Keycloak en {self.token_endpoint}: {e.reason}\n"
                f"Respuesta: {error_body}"
            )
            logger.error(msg)
            raise KeycloakAuthError(msg) from e
        except URLError as e:
            msg = (
                f"No se pudo conectar con Keycloak en {self.keycloak_url}: {e.reason}\n"
                "Asegurate de levantar la plataforma: ./setup.sh"
            )
            logger.error(msg)
            raise KeycloakAuthError(msg) from e
        except Exception as e:
            msg = f"Error inesperado solicitando token a Keycloak: {e}"
            logger.error(msg)
            raise KeycloakAuthError(msg) from e

        access_token = token_data.get("access_token")
        if not access_token:
            msg = (
                f"Keycloak no devolvio access_token. Respuesta: {token_data}"
            )
            logger.error(msg)
            raise KeycloakAuthError(msg)

        expires_in = token_data.get("expires_in", 300)
        self._expires_in = expires_in
        self._token = access_token
        self._refresh_token = token_data.get("refresh_token")
        self._token_at = time.time()

        # Calcular TTL efectivo para renovación anticipada antes de expiración
        if expires_in > (self.margin_seconds * 2):
            self._token_ttl = expires_in - self.margin_seconds
        else:
            self._token_ttl = max(5, expires_in // 2)

        logger.info(
            "Token Keycloak recibido con exito [grant=%s, client=%s, expires_in=%ds, renovacion_programada_a_los=%ds]",
            self.grant_type,
            self.client_id,
            expires_in,
            self._token_ttl,
        )
        return self._token


    def is_token_expired(self):
        """Indica si el token no existe o ha alcanzado su umbral de renovación."""
        if not self._token:
            return True
        elapsed = time.time() - self._token_at
        return elapsed >= self._token_ttl

    def get_access_token(self, force_refresh=False):
        """Retorna el access_token valido, renovandolo si ha alcanzado su TTL.

        Args:
            force_refresh: Forzar solicitud de token fresco ignorando cache.

        Returns:
            str: access_token JWT valido.
        """
        if force_refresh or self.is_token_expired():
            self.fetch_token()
        return self._token

    def get_auth_header(self, force_refresh=False):
        """Retorna la cabecera HTTP Authorization completa lista para usar.

        Args:
            force_refresh: Forzar renovacion de token.

        Returns:
            str: Header 'Bearer <access_token>'
        """
        token = self.get_access_token(force_refresh=force_refresh)
        return f"Bearer {token}"
