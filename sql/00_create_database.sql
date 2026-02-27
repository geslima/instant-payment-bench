IF DB_ID('InstantPaymentBench') IS NOT NULL
BEGIN
    ALTER DATABASE [InstantPaymentBench] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [InstantPaymentBench];
END
GO
CREATE DATABASE [InstantPaymentBench];
GO
ALTER DATABASE [InstantPaymentBench] SET RECOVERY FULL;
GO
ALTER DATABASE [InstantPaymentBench] SET AUTO_CLOSE OFF;
GO
ALTER DATABASE [InstantPaymentBench] SET AUTO_SHRINK OFF;
GO
ALTER DATABASE [InstantPaymentBench] SET AUTO_UPDATE_STATISTICS ON;
GO
ALTER DATABASE [InstantPaymentBench] SET AUTO_UPDATE_STATISTICS_ASYNC ON;
GO
ALTER DATABASE [InstantPaymentBench] SET READ_COMMITTED_SNAPSHOT ON;
GO
ALTER DATABASE [InstantPaymentBench] SET ALLOW_SNAPSHOT_ISOLATION ON;
GO
ALTER DATABASE [InstantPaymentBench] SET ACCELERATED_DATABASE_RECOVERY = ON;
GO
ALTER DATABASE [InstantPaymentBench] SET OPTIMIZED_LOCKING = ON;
GO
ALTER DATABASE [InstantPaymentBench] SET DELAYED_DURABILITY = DISABLED;
GO
ALTER DATABASE [InstantPaymentBench] SET PARAMETERIZATION FORCED;
GO
ALTER DATABASE [InstantPaymentBench] SET PAGE_VERIFY CHECKSUM;
GO
ALTER DATABASE [InstantPaymentBench] SET TARGET_RECOVERY_TIME = 60 SECONDS;
GO
ALTER DATABASE [InstantPaymentBench] SET ANSI_NULLS ON;
GO
ALTER DATABASE [InstantPaymentBench] SET ANSI_PADDING ON;
GO
ALTER DATABASE [InstantPaymentBench] SET ANSI_WARNINGS ON;
GO
ALTER DATABASE [InstantPaymentBench] SET ARITHABORT ON;
GO
ALTER DATABASE [InstantPaymentBench] SET CONCAT_NULL_YIELDS_NULL ON;
GO
ALTER DATABASE [InstantPaymentBench] SET QUOTED_IDENTIFIER ON;
GO
ALTER DATABASE [InstantPaymentBench] SET NUMERIC_ROUNDABORT OFF;
GO
ALTER DATABASE [InstantPaymentBench] SET RECURSIVE_TRIGGERS OFF;
GO
ALTER DATABASE [InstantPaymentBench] SET CURSOR_CLOSE_ON_COMMIT OFF;
GO
ALTER DATABASE [InstantPaymentBench] SET CURSOR_DEFAULT GLOBAL;
GO
ALTER DATABASE [InstantPaymentBench] SET DB_CHAINING OFF;
GO
ALTER DATABASE [InstantPaymentBench] SET TRUSTWORTHY OFF;
GO
ALTER DATABASE [InstantPaymentBench] SET HONOR_BROKER_PRIORITY OFF;
GO
ALTER DATABASE [InstantPaymentBench] SET MULTI_USER;
GO
ALTER DATABASE [InstantPaymentBench] SET FILESTREAM(NON_TRANSACTED_ACCESS = OFF);
GO
ALTER DATABASE [InstantPaymentBench] SET QUERY_STORE = ON;
GO
ALTER DATABASE [InstantPaymentBench] SET QUERY_STORE
(
    OPERATION_MODE              = READ_WRITE,
    CLEANUP_POLICY              = (STALE_QUERY_THRESHOLD_DAYS = 30),
    DATA_FLUSH_INTERVAL_SECONDS = 900,
    INTERVAL_LENGTH_MINUTES     = 60,
    MAX_STORAGE_SIZE_MB         = 1000,
    QUERY_CAPTURE_MODE          = AUTO,
    SIZE_BASED_CLEANUP_MODE     = AUTO,
    MAX_PLANS_PER_QUERY         = 200,
    WAIT_STATS_CAPTURE_MODE     = ON
);
GO

USE [InstantPaymentBench];
GO

CREATE TABLE [dbo].[Account]
(
    [AccountId]    BIGINT       NOT NULL,
    [BalanceCents] BIGINT       NOT NULL,
    [UpdatedAt]    DATETIME2(7) NOT NULL,
    CONSTRAINT [PK_Account] PRIMARY KEY CLUSTERED ([AccountId])
);
GO

CREATE TABLE [dbo].[Transfer]
(
    [TransferId]     BIGINT         IDENTITY(1,1) NOT NULL,
    [FromAccountId]  BIGINT         NOT NULL,
    [ToAccountId]    BIGINT         NOT NULL,
    [AmountCents]    INT            NOT NULL,
    [Status]         TINYINT        NOT NULL,
    [IdempotencyKey] VARCHAR(64)    NOT NULL,
    [CreatedAt]      DATETIME2(7)   NOT NULL,
    CONSTRAINT [PK_Transfer] PRIMARY KEY CLUSTERED ([TransferId]),
    CONSTRAINT [FK_Transfer_FromAccount] FOREIGN KEY ([FromAccountId]) REFERENCES [dbo].[Account] ([AccountId]),
    CONSTRAINT [FK_Transfer_ToAccount] FOREIGN KEY ([ToAccountId]) REFERENCES [dbo].[Account] ([AccountId]),
    CONSTRAINT [UQ_Transfer_IdempotencyKey] UNIQUE NONCLUSTERED ([IdempotencyKey])
);
GO

CREATE NONCLUSTERED INDEX [IX_Transfer_Status_CreatedAt] ON [dbo].[Transfer] ([Status], [CreatedAt]);
GO

CREATE TABLE [dbo].[LedgerEntry]
(
    [LedgerEntryId] BIGINT       IDENTITY(1,1) NOT NULL,
    [TransferId]    BIGINT       NOT NULL,
    [AccountId]     BIGINT       NOT NULL,
    [Direction]     CHAR(1)      NOT NULL,
    [AmountCents]   INT          NOT NULL,
    [CreatedAt]     DATETIME2(7) NOT NULL,
    CONSTRAINT [PK_LedgerEntry] PRIMARY KEY CLUSTERED ([LedgerEntryId]),
    CONSTRAINT [FK_LedgerEntry_Transfer] FOREIGN KEY ([TransferId]) REFERENCES [dbo].[Transfer] ([TransferId]),
    CONSTRAINT [FK_LedgerEntry_Account] FOREIGN KEY ([AccountId]) REFERENCES [dbo].[Account] ([AccountId]),
    CONSTRAINT [CHK_LedgerEntry_Direction] CHECK ([Direction] IN ('D','C'))
);
GO

CREATE NONCLUSTERED INDEX [IX_LedgerEntry_TransferId] ON [dbo].[LedgerEntry] ([TransferId]);
GO

PRINT N'';
PRINT N'InstantPaymentBench created successfully';
GO
