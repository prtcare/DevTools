// WorkbookLiveness.cs — minimal READ-ONLY structural health probe of the
// authoritative workbook. It only checks that the file opens as a valid OOXML
// package, counts the sheets, and computes the SHA-256. It performs NO business
// logic and never writes. Treats the workbook as the authoritative source.
using System.IO.Compression;
using System.Security.Cryptography;
using System.Xml.Linq;

namespace DevBridge.Engine;

public sealed record WorkbookLivenessResult(
    bool FileExists, bool Opens, bool ValidZip, int SheetCount, int ExpectedSheets,
    string? Sha256, string? Error);

public static class WorkbookLiveness
{
    public const int ExpectedSheets = 14;

    public static WorkbookLivenessResult Probe(string? workbookPath)
    {
        if (string.IsNullOrWhiteSpace(workbookPath) || !File.Exists(workbookPath))
            return new WorkbookLivenessResult(false, false, false, 0, ExpectedSheets, null, "Workbook file not found.");

        string sha;
        try { using var fs = File.OpenRead(workbookPath); sha = Convert.ToHexString(SHA256.HashData(fs)); }
        catch (IOException e) { return new WorkbookLivenessResult(true, false, false, 0, ExpectedSheets, null, e.Message); }

        int sheetCount;
        try
        {
            using var fs = File.OpenRead(workbookPath);
            using var zip = new ZipArchive(fs, ZipArchiveMode.Read);
            var entry = zip.GetEntry("xl/workbook.xml");
            if (entry is null) return new WorkbookLivenessResult(true, false, false, 0, ExpectedSheets, sha, "xl/workbook.xml missing.");
            using var sr = new StreamReader(entry.Open());
            var doc = XDocument.Load(sr);
            var xns = XNamespace.Get("http://schemas.openxmlformats.org/spreadsheetml/2006/main");
            sheetCount = doc.Root?.Element(xns + "sheets")?.Elements(xns + "sheet").Count() ?? 0;
        }
        catch (Exception e) when (e is IOException or InvalidDataException or System.Xml.XmlException)
        {
            return new WorkbookLivenessResult(true, false, false, 0, ExpectedSheets, sha, $"Open failed: {e.Message}");
        }

        bool validZip = sheetCount > 0;
        return new WorkbookLivenessResult(true, true, validZip, sheetCount, ExpectedSheets, sha,
            validZip ? null : "Workbook opened but reported zero sheets.");
    }
}
