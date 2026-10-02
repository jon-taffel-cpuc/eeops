"""
EE Ops -- CPUC Energy Division internal operations app (backend package).

Packages:
    eeops.config   Snowflake connection + object naming (env-driven)
    eeops.db       All Snowflake I/O (the only module that imports snowflake.connector)

Version: kept in sync with frontend/package.json. Only
deploy/01_auto_deploy_sf.sh bumps it -- do not edit by hand.
"""
__version__ = "0.1.2"
