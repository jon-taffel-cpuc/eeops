"""
EE Ops configuration -- connection params and object naming.

Inside Snowpark Container Services the platform injects SNOWFLAKE_ACCOUNT,
SNOWFLAKE_HOST and an OAuth token at /snowflake/session/token; nothing else
is required. For local development either run inside a CoCo sandbox (same
token file) or set SNOWFLAKE_CONNECTION_NAME to a connections.toml entry.

All EE Ops objects in CPUC_ED_DB.ENERGY_EFFICIENCY are prefixed EEOPS_ --
the schema is shared with CET_APP, CMS_APP and Canopy.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache
from typing import Optional


@dataclass(frozen=True)
class SnowflakeConfig:
    account: str = ""
    host: str = ""
    database: str = "CPUC_ED_DB"
    schema: str = "ENERGY_EFFICIENCY"
    warehouse: str = "CPUC_ED_TITLE20_S_WH"
    token_file: str = "/snowflake/session/token"
    role: Optional[str] = None
    connection_name: Optional[str] = None
    table_prefix: str = "EEOPS_"

    @classmethod
    def from_env(cls) -> "SnowflakeConfig":
        return cls(
            account=os.environ.get("SNOWFLAKE_ACCOUNT", ""),
            host=os.environ.get("SNOWFLAKE_HOST", ""),
            database=os.environ.get("EEOPS_DATABASE", "CPUC_ED_DB"),
            schema=os.environ.get("EEOPS_SCHEMA", "ENERGY_EFFICIENCY"),
            warehouse=os.environ.get("EEOPS_WAREHOUSE", "CPUC_ED_TITLE20_S_WH"),
            token_file=os.environ.get("SNOWFLAKE_TOKEN_FILE_PATH", "/snowflake/session/token"),
            role=os.environ.get("EEOPS_ROLE") or None,
            connection_name=os.environ.get("SNOWFLAKE_CONNECTION_NAME") or None,
        )

    @property
    def qualified_schema(self) -> str:
        return f"{self.database}.{self.schema}"

    def fq(self, name: str) -> str:
        """Fully-qualified name for an EE Ops object: fq('NOTES') -> CPUC_ED_DB.ENERGY_EFFICIENCY.EEOPS_NOTES."""
        return f"{self.qualified_schema}.{self.table_prefix}{name.upper()}"


@lru_cache(maxsize=1)
def get_config() -> SnowflakeConfig:
    return SnowflakeConfig.from_env()
