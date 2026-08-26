/*
    AD / Windows Login Audit Script
    --------------------------------
    Purpose:
      Given a Windows / AD login (DOMAIN\User), determine:

      1. How SQL Server resolves the login
      2. Effective server token memberships
      3. Server role memberships
      4. Explicit server permissions
      5. Database access across all online databases (except tempdb)
      6. Effective database principals
      7. Database role memberships
      8. Explicit database permissions

    Notes:
      - Best run as sysadmin for complete results
      - Uses xp_logininfo when available to show SQL permission path
      - Uses EXECUTE AS LOGIN to evaluate effective access as the target login
      - Skips tempdb because it is transient
*/

SET NOCOUNT ON;

DECLARE @TargetLogin sysname = N'DOMAIN\User'; -- <<<<<< CHANGE THIS
DECLARE @DbName sysname;
DECLARE @Sql NVARCHAR (MAX);

/*========================================================
  Temp tables
========================================================*/
IF OBJECT_ID('tempdb..#PermissionPath') IS NOT NULL
    DROP TABLE [#PermissionPath];

CREATE TABLE [#PermissionPath]
(
    [AccountName]     sysname         NULL
  , [AccountType]     NVARCHAR (60)   NULL
  , [Privilege]       NVARCHAR (60)   NULL
  , [MappedLoginName] sysname         NULL
  , [PermissionPath]  NVARCHAR (4000) NULL
);

IF OBJECT_ID('tempdb..#ServerToken') IS NOT NULL
    DROP TABLE [#ServerToken];

CREATE TABLE [#ServerToken]
(
    [PrincipalID]   INT            NULL
  , [SID]           VARBINARY (85) NULL
  , [PrincipalName] sysname        NULL
  , [PrincipalType] NVARCHAR (256) NULL
  , [UsageName]     NVARCHAR (256) NULL
);

IF OBJECT_ID('tempdb..#ServerRoleMembership') IS NOT NULL
    DROP TABLE [#ServerRoleMembership];

CREATE TABLE [#ServerRoleMembership]
(
    [RoleName]   sysname       NOT NULL
  , [MemberName] sysname       NOT NULL
  , [MemberType] NVARCHAR (60) NULL
);

IF OBJECT_ID('tempdb..#ServerPermissions') IS NOT NULL
    DROP TABLE [#ServerPermissions];

CREATE TABLE [#ServerPermissions]
(
    [GrantedTo]      sysname        NOT NULL
  , [PrincipalType]  NVARCHAR (60)  NULL
  , [PermissionName] sysname        NOT NULL
  , [StateDesc]      NVARCHAR (60)  NOT NULL
  , [ClassDesc]      NVARCHAR (60)  NOT NULL
  , [SecurableName]  NVARCHAR (512) NULL
);

IF OBJECT_ID('tempdb..#DatabaseAccess') IS NOT NULL
    DROP TABLE [#DatabaseAccess];

CREATE TABLE [#DatabaseAccess]
(
    [DatabaseName]      sysname NOT NULL
  , [HasAccess]         BIT     NOT NULL
  , [CurrentUserName]   sysname NULL
  , [OriginalLoginName] sysname NULL
);

IF OBJECT_ID('tempdb..#DatabasePrincipals') IS NOT NULL
    DROP TABLE [#DatabasePrincipals];

CREATE TABLE [#DatabasePrincipals]
(
    [DatabaseName]  sysname        NOT NULL
  , [PrincipalName] sysname        NULL
  , [PrincipalType] NVARCHAR (256) NULL
  , [UsageName]     NVARCHAR (256) NULL
);

IF OBJECT_ID('tempdb..#DatabaseRoleMembership') IS NOT NULL
    DROP TABLE [#DatabaseRoleMembership];

CREATE TABLE [#DatabaseRoleMembership]
(
    [DatabaseName]    sysname       NOT NULL
  , [MemberPrincipal] sysname       NOT NULL
  , [MemberType]      NVARCHAR (60) NULL
  , [RoleName]        sysname       NOT NULL
);

IF OBJECT_ID('tempdb..#DatabasePermissions') IS NOT NULL
    DROP TABLE [#DatabasePermissions];

CREATE TABLE [#DatabasePermissions]
(
    [DatabaseName]   sysname        NOT NULL
  , [PrincipalName]  sysname        NOT NULL
  , [PrincipalType]  NVARCHAR (60)  NULL
  , [PermissionName] sysname        NOT NULL
  , [StateDesc]      NVARCHAR (60)  NOT NULL
  , [ClassDesc]      NVARCHAR (60)  NOT NULL
  , [SecurableName]  NVARCHAR (512) NULL
);

IF OBJECT_ID('tempdb..#AuditNotes') IS NOT NULL
    DROP TABLE [#AuditNotes];

CREATE TABLE [#AuditNotes]
(
    [NoteType]  NVARCHAR (50)   NOT NULL
  , [ScopeName] sysname         NULL
  , [NoteText]  NVARCHAR (4000) NOT NULL
);

/*========================================================
  General login info
========================================================*/
INSERT INTO [#AuditNotes]
(
    [NoteType]
  , [ScopeName]
  , [NoteText]
)
SELECT
    N'Input'
  , @TargetLogin
  , N'Target login supplied for audit.';

IF SUSER_SID(@TargetLogin) IS NULL
    BEGIN
        INSERT INTO [#AuditNotes]
        (
            [NoteType]
          , [ScopeName]
          , [NoteText]
        )
        VALUES (
                   N'Warning'
                 , @TargetLogin
                 , N'SUSER_SID returned NULL for the supplied login. This can happen if the login does not exist as a SQL Server principal, cannot be resolved from AD, or the server cannot validate it. Some sections may return partial results.'
               );
    END;

/*========================================================
  1. SQL permission path using xp_logininfo
========================================================*/
BEGIN TRY
    INSERT INTO [#PermissionPath]
    (
        [AccountName]
      , [AccountType]
      , [Privilege]
      , [MappedLoginName]
      , [PermissionPath]
    )
    EXEC [master]..[xp_logininfo] @acctname = @TargetLogin, @option = 'all';
END TRY
BEGIN CATCH
    INSERT INTO [#AuditNotes]
    (
        [NoteType]
      , [ScopeName]
      , [NoteText]
    )
    VALUES (
               N'Info'
             , N'xp_logininfo'
             , N'xp_logininfo did not return results for this login. Error: ' + ERROR_MESSAGE()
           );
END CATCH;

/*========================================================
  2. Effective server token for target login
========================================================*/
BEGIN TRY
    SET @Sql = N'
        EXECUTE AS LOGIN = @L;

        INSERT INTO #ServerToken (PrincipalID, SID, PrincipalName, PrincipalType, UsageName)
        SELECT principal_id, sid, name, type, usage
        FROM sys.login_token;

        REVERT;
    ';

    EXEC [sys].[sp_executesql] @Sql, N'@L SYSNAME', @L = @TargetLogin;
END TRY
BEGIN CATCH
    BEGIN TRY
        REVERT;
    END TRY
    BEGIN CATCH
    END CATCH;

    INSERT INTO [#AuditNotes]
    (
        [NoteType]
      , [ScopeName]
      , [NoteText]
    )
    VALUES (
               N'Error'
             , N'ServerToken'
             , N'Unable to evaluate server token with EXECUTE AS LOGIN. Error: ' + ERROR_MESSAGE()
           );
END CATCH;

/*========================================================
  3. Direct server role memberships for all principals
     found in the effective token
========================================================*/
INSERT INTO [#ServerRoleMembership]
(
    [RoleName]
  , [MemberName]
  , [MemberType]
)
SELECT DISTINCT
       [R].[name]      AS [RoleName]
     , [M].[name]      AS [MemberName]
     , [M].[type_desc] AS [MemberType]
FROM
    [sys].[server_role_members]    AS [SRM]
    JOIN [sys].[server_principals] AS [R]
         ON [SRM].[role_principal_id] = [R].[principal_id]
    JOIN [sys].[server_principals] AS [M]
         ON [SRM].[member_principal_id] = [M].[principal_id]
    JOIN [#ServerToken]            AS [T]
         ON [T].[SID] = [M].[sid]
WHERE
    [R].[type] = 'R';

/*========================================================
  4. Explicit server permissions granted to token members
========================================================*/
INSERT INTO [#ServerPermissions]
(
    [GrantedTo]
  , [PrincipalType]
  , [PermissionName]
  , [StateDesc]
  , [ClassDesc]
  , [SecurableName]
)
SELECT DISTINCT
       [P].[name]      AS [GrantedTo]
     , [P].[type_desc] AS [PrincipalType]
     , [SP].[permission_name]
     , [SP].[state_desc]
     , [SP].[class_desc]
     , CASE
            WHEN [SP].[class_desc] = 'SERVER'
                 THEN N'(SERVER)'
            WHEN [SP].[class_desc] = 'ENDPOINT'
                 THEN [EP].[name]
            WHEN [SP].[class_desc] IN
                ( 'LOGIN', 'SERVER_ROLE' )
                 THEN [P2].[name]
            ELSE CONVERT(NVARCHAR (100), [SP].[major_id])
       END             AS [SecurableName]
FROM
    [sys].[server_permissions]          AS [SP]
    JOIN [sys].[server_principals]      AS [P]
         ON [SP].[grantee_principal_id] = [P].[principal_id]
    JOIN [#ServerToken]                 AS [T]
         ON [T].[SID] = [P].[sid]
    LEFT JOIN [sys].[endpoints]         AS [EP]
              ON [SP].[class_desc] = 'ENDPOINT'
                 AND [SP].[major_id] = [EP].[endpoint_id]
    LEFT JOIN [sys].[server_principals] AS [P2]
              ON [SP].[class_desc] IN
                     ( 'LOGIN', 'SERVER_ROLE' )
                 AND [SP].[major_id] = [P2].[principal_id];

/*========================================================
  5. Database level audit across all online databases
     except tempdb
========================================================*/
DECLARE [db_cursor] CURSOR LOCAL FAST_FORWARD FOR
    SELECT
        [name]
    FROM
        [sys].[databases]
    WHERE
        [state_desc] = 'ONLINE'
        AND [database_id] <> 2
    ORDER BY
        [name];

OPEN [db_cursor];

FETCH NEXT FROM [db_cursor]
INTO
    @DbName;

WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Sql = N'
        USE ' + QUOTENAME(@DbName)
                   + N';

        BEGIN TRY
            EXECUTE AS LOGIN = @L;

            IF HAS_DBACCESS(DB_NAME()) = 1
            BEGIN
                INSERT INTO #DatabaseAccess (DatabaseName, HasAccess, CurrentUserName, OriginalLoginName)
                SELECT DB_NAME(), 1, USER_NAME(), ORIGINAL_LOGIN();

                INSERT INTO #DatabasePrincipals (DatabaseName, PrincipalName, PrincipalType, UsageName)
                SELECT
                    DB_NAME(),
                    name,
                    type,
                    usage
                FROM sys.user_token;

                INSERT INTO #DatabaseRoleMembership (DatabaseName, MemberPrincipal, MemberType, RoleName)
                SELECT DISTINCT
                    DB_NAME(),
                    M.name AS MemberPrincipal,
                    M.type_desc AS MemberType,
                    R.name AS RoleName
                FROM sys.database_role_members DRM
                JOIN sys.database_principals R
                    ON DRM.role_principal_id = R.principal_id
                JOIN sys.database_principals M
                    ON DRM.member_principal_id = M.principal_id
                JOIN sys.user_token UT
                    ON UT.sid = M.sid
                WHERE R.type = ''R'';

                INSERT INTO #DatabasePermissions
                (
                    DatabaseName,
                    PrincipalName,
                    PrincipalType,
                    PermissionName,
                    StateDesc,
                    ClassDesc,
                    SecurableName
                )
                SELECT DISTINCT
                    DB_NAME(),
                    DP.name AS PrincipalName,
                    DP.type_desc AS PrincipalType,
                    PERM.permission_name,
                    PERM.state_desc,
                    PERM.class_desc,
                    CASE
                        WHEN PERM.class_desc = ''DATABASE'' THEN DB_NAME()
                        WHEN PERM.class_desc = ''SCHEMA'' THEN QUOTENAME(S.name)
                        WHEN PERM.class_desc = ''OBJECT_OR_COLUMN'' THEN
                            ISNULL
                            (
                                QUOTENAME(OBJECT_SCHEMA_NAME(PERM.major_id)) + N''.'' + QUOTENAME(OBJECT_NAME(PERM.major_id)),
                                CONVERT(NVARCHAR(100), PERM.major_id)
                            )
                        ELSE CONVERT(NVARCHAR(100), PERM.major_id)
                    END AS SecurableName
                FROM sys.database_permissions PERM
                JOIN sys.database_principals DP
                    ON PERM.grantee_principal_id = DP.principal_id
                JOIN sys.user_token UT
                    ON UT.sid = DP.sid
                LEFT JOIN sys.schemas S
                    ON PERM.class_desc = ''SCHEMA''
                   AND PERM.major_id = S.schema_id;
            END
            ELSE
            BEGIN
                INSERT INTO #DatabaseAccess (DatabaseName, HasAccess, CurrentUserName, OriginalLoginName)
                SELECT DB_NAME(), 0, NULL, ORIGINAL_LOGIN();
            END

            REVERT;
        END TRY
        BEGIN CATCH
            BEGIN TRY
                REVERT;
            END TRY
            BEGIN CATCH
            END CATCH;

            INSERT INTO #AuditNotes (NoteType, ScopeName, NoteText)
            VALUES
            (
                N''DatabaseError'',
                DB_NAME(),
                N''Database audit failed. Error: '' + ERROR_MESSAGE()
            );
        END CATCH;
    '   ;

        BEGIN TRY
            EXEC [sys].[sp_executesql] @Sql, N'@L SYSNAME', @L = @TargetLogin;
        END TRY
        BEGIN CATCH
            INSERT INTO [#AuditNotes]
            (
                [NoteType]
              , [ScopeName]
              , [NoteText]
            )
            VALUES (
                       N'DatabaseError', @DbName, N'Outer execution failed for database. Error: ' + ERROR_MESSAGE()
                   );
        END CATCH;

        FETCH NEXT FROM [db_cursor]
        INTO
            @DbName;
    END;

CLOSE [db_cursor];
DEALLOCATE [db_cursor];

/*========================================================
  Final report output
========================================================*/
PRINT REPLICATE('=', 90);
PRINT 'AUDIT TARGET: ' + ISNULL(@TargetLogin, N'<NULL>');
PRINT REPLICATE('=', 90);

/* 0. Notes */
SELECT
    [NoteType]
  , [ScopeName]
  , [NoteText]
FROM
    [#AuditNotes]
ORDER BY
    CASE [NoteType]
         WHEN 'Error'
              THEN 1
         WHEN 'DatabaseError'
              THEN 2
         WHEN 'Warning'
              THEN 3
         WHEN 'Info'
              THEN 4
         ELSE 5
    END
  , [ScopeName];

/* 1. Matching server principal, if present */
SELECT
    [SP].[name]
  , [SP].[type_desc]
  , [SP].[is_disabled]
  , [SP].[default_database_name]
  , [SP].[default_language_name]
  , [SP].[create_date]
  , [SP].[modify_date]
FROM
    [sys].[server_principals] AS [SP]
WHERE
    [SP].[name] = @TargetLogin;

/* 2. SQL permission path via xp_logininfo */
SELECT
    [AccountName]
  , [AccountType]
  , [Privilege]
  , [MappedLoginName]
  , [PermissionPath]
FROM
    [#PermissionPath]
ORDER BY
    [AccountName]
  , [PermissionPath];

/* 3. Effective server token memberships */
SELECT
    [PrincipalName]
  , [PrincipalType]
  , [UsageName]
FROM
    [#ServerToken]
ORDER BY
    [PrincipalType]
  , [PrincipalName];

/* 4. Direct server role memberships for token members */
SELECT
    [RoleName]
  , [MemberName]
  , [MemberType]
FROM
    [#ServerRoleMembership]
ORDER BY
    [RoleName]
  , [MemberName];

/* 5. Explicit server permissions granted to token members */
SELECT
    [GrantedTo]
  , [PrincipalType]
  , [PermissionName]
  , [StateDesc]
  , [ClassDesc]
  , [SecurableName]
FROM
    [#ServerPermissions]
ORDER BY
    [GrantedTo]
  , [ClassDesc]
  , [PermissionName]
  , [SecurableName];

/* 6. Database access summary */
SELECT
    [DatabaseName]
  , [HasAccess]
  , [CurrentUserName]
  , [OriginalLoginName]
FROM
    [#DatabaseAccess]
ORDER BY
    [DatabaseName];

/* 7. Effective database principals */
SELECT
    [DatabaseName]
  , [PrincipalName]
  , [PrincipalType]
  , [UsageName]
FROM
    [#DatabasePrincipals]
ORDER BY
    [DatabaseName]
  , [PrincipalType]
  , [PrincipalName];

/* 8. Database role memberships */
SELECT
    [DatabaseName]
  , [MemberPrincipal]
  , [MemberType]
  , [RoleName]
FROM
    [#DatabaseRoleMembership]
ORDER BY
    [DatabaseName]
  , [RoleName]
  , [MemberPrincipal];

/* 9. Explicit database permissions */
SELECT
    [DatabaseName]
  , [PrincipalName]
  , [PrincipalType]
  , [PermissionName]
  , [StateDesc]
  , [ClassDesc]
  , [SecurableName]
FROM
    [#DatabasePermissions]
ORDER BY
    [DatabaseName]
  , [PrincipalName]
  , [ClassDesc]
  , [PermissionName]
  , [SecurableName];