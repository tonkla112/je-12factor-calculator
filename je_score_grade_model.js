(function () {
  const model = {
    version: 'JE-SGM-2026-08-21-calibrated-v1',
    basis: 'Benchmark-derived score bands calibrated from the 100-role JE reference dataset.',
    benchmarkRoleCount: 100,
    benchmarkFit: {
      exactMatches: 88,
      adjacentBoundaryReviewRoles: 12,
      note: 'Some benchmark roles sit intentionally near adjacent-level boundaries; review final levels through committee calibration rather than total score alone.',
    },
    minFactorScore: 10,
    maxFactorScore: 100,
    maxTotalScore: 1200,
    boundaryReviewPoints: 15,
    bands: [
      { level: 'L1', min: 120, max: 456, titles: { th: 'พนักงานปฏิบัติการ / เจ้าหน้าที่ระดับต้น', en: 'Operator / Entry-level Staff', zh: '操作员 / 职员' } },
      { level: 'L2', min: 457, max: 534, titles: { th: 'พนักงานปฏิบัติการอาวุโส / เจ้าหน้าที่', en: 'Senior Operator / Staff', zh: '专员 / 技术员' } },
      { level: 'L3', min: 535, max: 591, titles: { th: 'เจ้าหน้าที่อาวุโส / หัวหน้างาน (Supervisor)', en: 'Senior Staff / Supervisor', zh: '高级专员' } },
      { level: 'L4', min: 592, max: 657, titles: { th: 'หัวหน้างานอาวุโส / ผู้ช่วยผู้จัดการ', en: 'Senior Supervisor / Assistant Manager', zh: '专业人员' } },
      { level: 'L5', min: 658, max: 717, titles: { th: 'ผู้จัดการแผนก (Section/Department Manager)', en: 'Section/Department Manager', zh: '经理' } },
      { level: 'L6', min: 718, max: 782, titles: { th: 'ผู้จัดการอาวุโส (Senior Manager)', en: 'Senior Manager', zh: '高级经理' } },
      { level: 'L7', min: 783, max: 854, titles: { th: 'ผู้อำนวยการ / ผู้จัดการโรงงาน (Director/Plant Manager)', en: 'Director / Plant Manager', zh: '总监' } },
      { level: 'L8', min: 855, max: 1200, titles: { th: 'ผู้บริหารระดับสูง (Executive/VP ขึ้นไป)', en: 'Senior Executive (VP and above)', zh: '董事总经理' } },
    ],
  };
  model.levelForScore = function (score) {
    const numericScore = Number(score);
    if (!Number.isFinite(numericScore)) return model.bands[0].level;
    const belowOrAtMinimum = numericScore <= model.bands[0].max;
    if (belowOrAtMinimum) return model.bands[0].level;
    const match = model.bands.find(b => numericScore >= b.min && numericScore <= b.max);
    return match ? match.level : model.bands[model.bands.length - 1].level;
  };
  model.bandForScore = function (score) {
    const level = model.levelForScore(score);
    return model.bands.find(b => b.level === level) || model.bands[0];
  };
  model.boundaryReview = function (score) {
    const numericScore = Number(score);
    if (!Number.isFinite(numericScore)) return null;
    for (let i = 0; i < model.bands.length - 1; i++) {
      const boundary = model.bands[i].max;
      const distance = Math.abs(numericScore - boundary);
      if (distance <= model.boundaryReviewPoints) {
        return {
          boundary,
          lowerLevel: model.bands[i].level,
          upperLevel: model.bands[i + 1].level,
          distance,
        };
      }
    }
    return null;
  };
  window.JE_SCORE_GRADE_MODEL = model;
}());
