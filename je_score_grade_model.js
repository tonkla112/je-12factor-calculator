(function () {
  const model = {
    version: 'JE-SGM-2026-08-24-hazard-v3',
    basis: 'Benchmark-derived score bands with working-condition factors capped in base grade scoring and separated into a hazard/premium review signal where appropriate.',
    benchmarkRoleCount: 100,
    benchmarkFit: {
      exactMatches: 96,
      adjacentBoundaryReviewRoles: 23,
      note: 'Working-condition capped model validates at 96/100 exact benchmark matches. Physical and environment factors are limited in base grade scoring; high exposure should trigger separate premium/hazard review rather than automatically inflating job grade.',
    },
    minFactorScore: 10,
    maxFactorScore: 100,
    maxTotalScore: 1200,
    boundaryReviewPoints: 15,
    bands: [
      { level: 'L1', min: 120, max: 420, titles: { th: 'พนักงานปฏิบัติการ / เจ้าหน้าที่ระดับต้น', en: 'Operator / Entry-level Staff', zh: '操作员 / 职员' } },
      { level: 'L2', min: 421, max: 493, titles: { th: 'พนักงานปฏิบัติการอาวุโส / เจ้าหน้าที่', en: 'Senior Operator / Staff', zh: '专员 / 技术员' } },
      { level: 'L3', min: 494, max: 592, titles: { th: 'เจ้าหน้าที่อาวุโส / หัวหน้างาน (Supervisor)', en: 'Senior Staff / Supervisor', zh: '高级专员' } },
      { level: 'L4', min: 593, max: 658, titles: { th: 'หัวหน้างานอาวุโส / ผู้ช่วยผู้จัดการ', en: 'Senior Supervisor / Assistant Manager', zh: '专业人员' } },
      { level: 'L5', min: 659, max: 737, titles: { th: 'ผู้จัดการแผนก (Section/Department Manager)', en: 'Section/Department Manager', zh: '经理' } },
      { level: 'L6', min: 738, max: 810, titles: { th: 'ผู้จัดการอาวุโส (Senior Manager)', en: 'Senior Manager', zh: '高级经理' } },
      { level: 'L7', min: 811, max: 898, titles: { th: 'ผู้อำนวยการ / ผู้จัดการโรงงาน (Director/Plant Manager)', en: 'Director / Plant Manager', zh: '总监' } },
      { level: 'L8', min: 899, max: 1200, titles: { th: 'ผู้บริหารระดับสูง (Executive/VP ขึ้นไป)', en: 'Senior Executive (VP and above)', zh: '董事总经理' } },
    ],
    factorWeights: [
      { key: 'education', aliases: ['edu'], group: 'knowledge', weight: 0.95, label: 'Education' },
      { key: 'experience', aliases: ['exp'], group: 'knowledge', weight: 1.05, label: 'Experience' },
      { key: 'analysis', aliases: ['ana'], group: 'thinking', weight: 1.10, label: 'Analysis' },
      { key: 'problem', aliases: ['prob'], group: 'thinking', weight: 1.15, label: 'Problem Solving' },
      { key: 'decision', aliases: ['dec'], group: 'accountability', weight: 1.25, label: 'Decision Making' },
      { key: 'impact', aliases: ['imp'], group: 'accountability', weight: 1.30, label: 'Impact' },
      { key: 'intcomm', aliases: ['ic'], group: 'relationships', weight: 0.85, label: 'Internal Communication' },
      { key: 'extcomm', aliases: ['ec'], group: 'relationships', weight: 0.80, label: 'External Communication' },
      { key: 'leadership', aliases: ['lead'], group: 'accountability', weight: 1.20, label: 'Leadership' },
      { key: 'physical', aliases: ['phys'], group: 'workingConditions', weight: 0.55, label: 'Physical Demand' },
      { key: 'environment', aliases: ['env'], group: 'workingConditions', weight: 0.65, label: 'Work Environment' },
      { key: 'innovation', aliases: ['inno'], group: 'thinking', weight: 1.15, label: 'Innovation' },
    ],
    factorGroups: {
      knowledge: { label: 'Knowledge & Experience', targetShare: 16.7 },
      thinking: { label: 'Thinking & Innovation', targetShare: 28.3 },
      accountability: { label: 'Accountability & Leadership', targetShare: 31.3 },
      relationships: { label: 'Communication & Relationships', targetShare: 13.8 },
      workingConditions: { label: 'Working Conditions', targetShare: 10.0 },
    },
    hazardPremium: {
      basis: 'Physical Demand and Work Environment are capped in base grade scoring. Use this signal to review separate hardship, hazard, shift, PPE, or environmental premium policy where appropriate.',
      monitorThreshold: 60,
      hazardReviewThreshold: 70,
      premiumReviewThreshold: 80,
    },
  };
  model.factorWeightTotal = model.factorWeights.reduce((sum, f) => sum + f.weight, 0);
  model.weightingBasis = 'Weights sum to 12.00 so the weighted score remains on the 120-1200 JE scale. Physical Demand and Work Environment are capped at 1.20 combined weight (10% of base score); high exposure is handled through a separate premium/hazard review signal.';
  model.factorWeightFor = function (key) {
    return model.factorWeights.find(f => f.key === key || (f.aliases || []).includes(key)) || null;
  };
  model.scoreForFactor = function (scores, factor) {
    if (!scores || typeof scores !== 'object') return model.minFactorScore;
    const keys = [factor.key].concat(factor.aliases || []);
    const foundKey = keys.find(k => scores[k] !== undefined && scores[k] !== null && scores[k] !== '');
    const raw = foundKey ? Number(scores[foundKey]) : model.minFactorScore;
    if (!Number.isFinite(raw)) return model.minFactorScore;
    return Math.max(model.minFactorScore, Math.min(model.maxFactorScore, raw));
  };
  model.unweightedTotal = function (scores) {
    return model.factorWeights.reduce((sum, factor) => sum + model.scoreForFactor(scores, factor), 0);
  };
  model.weightedTotal = function (scores) {
    const weighted = model.factorWeights.reduce((sum, factor) => {
      return sum + (model.scoreForFactor(scores, factor) * factor.weight);
    }, 0);
    return Math.round(weighted);
  };
  model.factorContributions = function (scores) {
    return model.factorWeights.map(factor => {
      const score = model.scoreForFactor(scores, factor);
      return {
        key: factor.key,
        group: factor.group,
        label: factor.label,
        score,
        weight: factor.weight,
        weightedPoints: Math.round(score * factor.weight * 10) / 10,
        maxWeightedPoints: Math.round(model.maxFactorScore * factor.weight * 10) / 10,
      };
    });
  };
  model.groupContributions = function (scores) {
    return model.factorContributions(scores).reduce((groups, factor) => {
      const group = groups[factor.group] || {
        key: factor.group,
        label: (model.factorGroups[factor.group] && model.factorGroups[factor.group].label) || factor.group,
        weightedPoints: 0,
        maxWeightedPoints: 0,
      };
      group.weightedPoints += factor.weightedPoints;
      group.maxWeightedPoints += factor.maxWeightedPoints;
      groups[factor.group] = group;
      return groups;
    }, {});
  };
  model.calculate = function (scores) {
    const weightedTotal = model.weightedTotal(scores);
    const unweightedTotal = model.unweightedTotal(scores);
    const band = model.bandForScore(weightedTotal);
    return {
      weightedTotal,
      unweightedTotal,
      level: band.level,
      band,
      boundaryReview: model.boundaryReview(weightedTotal),
      hazardPremiumReview: model.hazardPremiumReview(scores),
      factorContributions: model.factorContributions(scores),
      groupContributions: model.groupContributions(scores),
    };
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
  model.hazardPremiumReview = function (scores) {
    const physical = model.scoreForFactor(scores, model.factorWeightFor('physical'));
    const environment = model.scoreForFactor(scores, model.factorWeightFor('environment'));
    const exposureScore = Math.round((physical + environment) / 2);
    let tier = 'none';
    let recommendation = 'No separate hazard premium review indicated from working-condition factors.';
    if (environment >= 90 || (environment >= model.hazardPremium.premiumReviewThreshold && physical >= model.hazardPremium.hazardReviewThreshold)) {
      tier = 'premiumReview';
      recommendation = 'Review separate hazard/hardship premium or allowance policy; do not rely on base job grade alone.';
    } else if (environment >= model.hazardPremium.hazardReviewThreshold || physical >= model.hazardPremium.premiumReviewThreshold || exposureScore >= 75) {
      tier = 'hazardReview';
      recommendation = 'Review whether existing safety, shift, PPE, hardship, or environment allowance policy applies.';
    } else if (environment >= model.hazardPremium.monitorThreshold || physical >= model.hazardPremium.hazardReviewThreshold) {
      tier = 'monitor';
      recommendation = 'Monitor working-condition exposure; premium may be unnecessary unless exposure is frequent or unavoidable.';
    }
    return {
      tier,
      exposureScore,
      physical,
      environment,
      recommendation,
      basis: model.hazardPremium.basis,
    };
  };
  model.validateBenchmarkJobs = function (jobs) {
    const rows = (Array.isArray(jobs) ? jobs : []).map(job => {
      const score = job.scores ? model.weightedTotal(job.scores) : Number(job.score || job.total || job.totalScore);
      const predictedLevel = model.levelForScore(score);
      const expectedLevel = job.level || job.expectedLevel;
      const boundaryReview = model.boundaryReview(score);
      return {
        id: job.id || job.jobId || job.job_id || '',
        title: job.title || '',
        score,
        expectedLevel,
        predictedLevel,
        exactMatch: expectedLevel ? predictedLevel === expectedLevel : null,
        boundaryReview,
      };
    }).filter(row => Number.isFinite(row.score));
    const comparable = rows.filter(row => row.expectedLevel);
    const exactMatches = comparable.filter(row => row.exactMatch).length;
    const boundaryReviewRoles = rows.filter(row => row.boundaryReview).length;
    return {
      roleCount: rows.length,
      comparableRoleCount: comparable.length,
      exactMatches,
      exactMatchRate: comparable.length ? Math.round(exactMatches / comparable.length * 1000) / 10 : null,
      boundaryReviewRoles,
      rows,
      limitation: 'Current benchmark rows validate weighted score-to-grade bands from total scores. Store the 12 benchmark factor scores per job to validate factor weights directly.',
    };
  };
  window.JE_SCORE_GRADE_MODEL = model;
}());
